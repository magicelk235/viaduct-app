import { readFileSync, writeFileSync, copyFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
const TEMPLATE_DIR = join(dirname(fileURLToPath(import.meta.url)), "templates");
export const SIDEPANEL_INJECT = "sidepanel-inject.js";
export const SIDEPANEL_BG = "sidepanel-bg.js";
const PANEL_CANDIDATES = ["sidepanel.html", "panel.html", "side_panel.html"];
/**
 * Fake a Chrome side panel in Safari, which has no native one.
 *
 * Chrome extensions expose their panel as a docked `sidePanel` or as an action
 * popup. Converted to Safari, the popup becomes a tiny detached popover — not a
 * panel. This rewires the extension so the toolbar button toggles the panel
 * docked to the right of the page instead:
 *   - sidepanel-inject.js : content script that injects sidepanel.html in an
 *     extension-origin iframe docked right, shifts the page, and toggles on a
 *     "c2s-toggle-sidepanel" message.
 *   - sidepanel-bg.js     : background hook — action.onClicked → send the toggle
 *     message to the active tab (replaces the popover).
 *
 * No-op unless a panel HTML file exists. Mutates `manifest`. Returns notes.
 */
export function applySidepanel(stageDir, manifest, shimFile) {
    const notes = [];
    const panel = PANEL_CANDIDATES.find((c) => existsSync(join(stageDir, c)));
    if (!panel)
        return notes; // nothing that looks like a side panel
    // Does the extension already drive the toolbar button itself (its own
    // action.onClicked, which the shim reroutes via sidePanel.open)? If so we
    // don't add our own toggle handler — that would double-fire.
    const hasActionHandler = backgroundUsesActionClick(stageDir, manifest);
    // 1. Emit the inject content script.
    copyFileSync(join(TEMPLATE_DIR, SIDEPANEL_INJECT), join(stageDir, SIDEPANEL_INJECT));
    // If the panel file isn't literally sidepanel.html, point the inject at it.
    if (panel !== "sidepanel.html") {
        const p = join(stageDir, SIDEPANEL_INJECT);
        writeFileSync(p, readFileSync(p, "utf-8").replace("sidepanel.html", panel), "utf-8");
    }
    // 2. Turn the action into a click action (no popover) so onClicked fires.
    const actionKey = manifest.action ? "action" : manifest.browser_action ? "browser_action" : "action";
    const action = manifest[actionKey] ?? {};
    delete action.default_popup;
    action.default_title = action.default_title ?? "Toggle panel";
    manifest[actionKey] = action;
    // 3. Inject the inject script on every page (with the shim first so chrome.*
    //    is patched), document_idle so the DOM exists.
    manifest.content_scripts = manifest.content_scripts ?? [];
    const js = shimFile ? [shimFile, SIDEPANEL_INJECT] : [SIDEPANEL_INJECT];
    manifest.content_scripts.push({ js, matches: ["<all_urls>"], run_at: "document_idle", all_frames: false });
    // 4. The panel HTML loads in an iframe → must be web-accessible to all pages.
    addWebAccessible(manifest, panel, ["<all_urls>"]);
    // The extension's own onClicked → chrome.sidePanel.open() is rerouted by the
    // shim to message the injected panel, so no extra background relay is needed.
    // But if the extension has NO action handler at all, add one that toggles.
    if (!hasActionHandler) {
        ensureToggleBackground(stageDir, manifest);
    }
    notes.push(`Side panel wired: toolbar button toggles ${panel} docked right (Safari has no native side panel)`);
    return notes;
}
/**
 * True if the extension's own background script handles the toolbar click (a
 * direct action.onClicked, or sidePanel.open which the shim reroutes). When it
 * does, the click already drives the panel and we must NOT add a second handler.
 */
function backgroundUsesActionClick(stageDir, manifest) {
    const bg = manifest.background ?? {};
    const entry = bg.service_worker || bg.page;
    if (!entry)
        return false;
    // The entry may be an HTML page that loads JS; scan all staged .js for the calls.
    const probe = /onClicked\s*\.\s*addListener|sidePanel\s*\.\s*(open|setPanelBehavior)/;
    try {
        const swPath = bg.service_worker ? join(stageDir, bg.service_worker) : null;
        if (swPath && existsSync(swPath) && probe.test(readFileSync(swPath, "utf-8")))
            return true;
    }
    catch { /* fall through to dir scan */ }
    // Broad scan: assets bundles often hold the SW logic under hashed names.
    try {
        for (const f of walkJs(stageDir)) {
            if (probe.test(readFileSync(f, "utf-8")))
                return true;
        }
    }
    catch { /* ignore */ }
    return false;
}
function walkJs(dir, out = []) {
    for (const name of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, name.name);
        if (name.isDirectory())
            walkJs(p, out);
        else if (name.name.endsWith(".js"))
            out.push(p);
    }
    return out;
}
/**
 * Fallback for extensions with NO click handler of their own: emit a tiny
 * background relay that toggles the injected panel on action.onClicked.
 */
function ensureToggleBackground(stageDir, manifest) {
    copyFileSync(join(TEMPLATE_DIR, SIDEPANEL_BG), join(stageDir, SIDEPANEL_BG));
    const bg = manifest.background ?? {};
    if (bg.page) {
        const pagePath = join(stageDir, bg.page);
        if (existsSync(pagePath)) {
            let html = readFileSync(pagePath, "utf-8");
            if (!html.includes(SIDEPANEL_BG))
                writeFileSync(pagePath, `<script src="${SIDEPANEL_BG}"></script>\n` + html, "utf-8");
            return;
        }
    }
    if (bg.service_worker) {
        const swPath = join(stageDir, bg.service_worker);
        if (existsSync(swPath)) {
            const src = readFileSync(swPath, "utf-8");
            if (!src.includes(SIDEPANEL_BG))
                writeFileSync(swPath, `import "./${SIDEPANEL_BG}";\n` + src, "utf-8");
            return;
        }
    }
    // No background at all: create one.
    writeFileSync(join(stageDir, "background.html"), `<!DOCTYPE html><meta charset="utf-8">\n<script src="${SIDEPANEL_BG}"></script>\n`, "utf-8");
    manifest.background = { page: "background.html", persistent: false };
}
/** Ensure `resource` is exposed to `matches` in web_accessible_resources (MV3). */
function addWebAccessible(manifest, resource, matches) {
    const war = Array.isArray(manifest.web_accessible_resources) ? manifest.web_accessible_resources : [];
    const already = war.some((e) => e && Array.isArray(e.resources) && e.resources.includes(resource));
    if (!already)
        war.push({ resources: [resource], matches, use_dynamic_url: false });
    manifest.web_accessible_resources = war;
}
