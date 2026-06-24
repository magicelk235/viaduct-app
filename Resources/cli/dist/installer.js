import { mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { run, info, ok, warn, moveBundle } from "./util.js";
import { pluginkitStatus } from "./packager.js";
/** Full path to LaunchServices' lsregister (not on PATH). */
export const LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
/** Expand a leading ~ to the user's home directory. */
export function expandHome(p) {
    if (p === "~")
        return homedir();
    if (p.startsWith("~/"))
        return join(homedir(), p.slice(2));
    return p;
}
/** True when pluginkit's output lists the extension's bundle id. */
export function bundleRegistered(pluginkitOutput, bundleId) {
    return pluginkitOutput.includes(bundleId);
}
function safariRunning() {
    return run("/usr/bin/pgrep", ["-x", "Safari"]).code === 0;
}
/**
 * Install the built host app so its Safari extension persists across Safari
 * restarts: copy to a stable dir, register with LaunchServices, optionally
 * enable Safari's unsigned-extension toggle and bounce Safari, then launch the
 * host app so Safari registers the appex.
 */
export function installToSafari(opts) {
    const result = {
        installedAppPath: null,
        registered: false,
        unsignedToggleSet: false,
    };
    const targetDir = expandHome(opts.installDir ?? "~/Applications");
    mkdirSync(targetDir, { recursive: true });
    const dest = join(targetDir, `${opts.appName}.app`);
    info(`Installing host app → ${dest}`);
    // Move (not copy) the signed Release product here, leaving no duplicate behind. A
    // same-volume rename is atomic and preserves the signature/seal untouched.
    if (!moveBundle(opts.builtAppPath, dest)) {
        warn(`Install move failed: ${opts.builtAppPath} → ${dest}`);
        return result;
    }
    result.installedAppPath = dest;
    ok(`Moved host app to ${dest}`);
    // The build already signs with the App Sandbox entitlement and seals the bundle; the
    // move preserves that. Do NOT re-sign here — a plain `codesign --sign -` would strip
    // the entitlements and Safari would stop registering the appex.
    const reg = run(LSREGISTER, ["-f", dest]);
    if (reg.code === 0)
        ok("Registered with LaunchServices");
    else
        warn(`lsregister exit ${reg.code} — Safari may take a moment to see the app.`);
    // A team-signed extension loads without the (session-scoped) unsigned toggle, so skip
    // the whole Safari quit/toggle/relaunch dance when signed.
    const applyUnsigned = !opts.signed && opts.safariRestart;
    if (applyUnsigned) {
        if (safariRunning()) {
            warn("Quitting Safari to apply the unsigned-extension setting …");
            run("/usr/bin/osascript", ["-e", 'tell application "Safari" to quit']);
        }
        const def = run("/usr/bin/defaults", [
            "write",
            "com.apple.Safari",
            "AllowUnsignedAppExtensions",
            "-bool",
            "true",
        ]);
        if (def.code === 0) {
            result.unsignedToggleSet = true;
            ok('Set Safari "Allow Unsigned Extensions" = true');
        }
        else {
            warn('Could not set "Allow Unsigned Extensions"; enable it manually (Develop menu).');
        }
    }
    // Launch the host app once so macOS/pluginkit registers the extension, but
    // do it in the background and hidden (-g -j) so it doesn't pop to the
    // foreground. The user opens it themselves via the app's "Open extension"
    // button when they're ready.
    info("Registering the extension (host app launched in background) …");
    run("/usr/bin/open", ["-g", "-j", dest]);
    if (applyUnsigned)
        run("/usr/bin/open", ["-g", "-a", "Safari"]);
    result.registered = bundleRegistered(pluginkitStatus(), opts.bundleId);
    if (result.registered)
        ok("pluginkit lists the extension as registered.");
    else
        warn("pluginkit has not listed the extension yet (give Safari a moment, then check Settings → Extensions).");
    return result;
}
