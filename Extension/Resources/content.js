function installViaduct(extId, name, btn) {
  let url = `viaduct://install?id=${extId}`;
  if (name) url += `&name=${encodeURIComponent(name)}`;
  window.location.href = url;
  // The app converts headless (no Viaduct window); the button becomes the UI.
  startProgressPolling(btn);
}

function removeChromePromos() {
  // The blue "Switch to Chrome to install extensions and themes" banner has no stable
  // id/class. The phrase bubbles up through every ancestor to <body>, so matching on
  // textContent alone would hide the whole page. Only hide elements that are themselves
  // banner-shaped: short (a row, not the page) and visible. visibility:hidden keeps
  // layout out of the way without collapsing siblings.
  const all = document.querySelectorAll('div, section, aside');
  for (const el of all) {
    if (!(el.textContent || '').toLowerCase().includes('switch to chrome to install')) continue;
    const h = el.offsetHeight;
    if (h > 0 && h < 120) { el.style.display = 'none'; }
  }
}

// Pill styling for the button we inject ourselves (also reapplied after a
// progress-card dismissal, which wipes inline styles).
const VD_BTN_CSS =
  'display:inline-flex;align-items:center;margin:10px 0;padding:10px 20px;' +
  'background:#4A9DAD;color:#0A1A1E;border:none;border-radius:99px;' +
  'font:600 14px/1 -apple-system,BlinkMacSystemFont,sans-serif;cursor:pointer;' +
  // The title header is a grid; without these the button gets squeezed into
  // a ~60px column and the label wraps.
  'white-space:nowrap;width:max-content';

// The store's client-side router omits its install button entirely on
// non-Chrome browsers: the initial server-rendered HTML has one (we relabel
// it), but SPA navigation re-renders the header without it, leaving nothing
// to repurpose — the button "disappears" when browsing between extensions.
// Inject our own below the title whenever a detail page has no button at all.
// A surviving store button (relabeled or not) or live progress card, other
// than `skip` (our own injected button).
function storeInstallButton(skip) {
  const phrases = ['add to safari', 'available on chrome', 'add to chrome', 'get chrome'];
  for (const btn of document.querySelectorAll('button, [role="button"], a')) {
    if (btn === skip) continue;
    if (btn.dataset.vdProgress) return btn;
    // Google keeps previous SPA views in the DOM inside display:none
    // containers — their leftover buttons don't count as present.
    if (!btn.offsetHeight) continue;
    const text = (btn.textContent || '').toLowerCase().trim();
    if (text.length < 60 && phrases.some(p => text.includes(p))) return btn;
  }
  return null;
}

function ensureInstallButton() {
  const injected = document.querySelector('.vd-install');
  // Never touch an injected button that became the live progress card.
  if (injected && injected.dataset.vdProgress) return;
  const onDetail = /\/detail\/[^/]+\/[a-z]{32}/.test(window.location.pathname);
  const store = storeInstallButton(injected);
  // A hidden injected button sits in a dead SPA view — stale, replace it.
  const keep = onDetail && !store && injected && injected.offsetHeight > 0;
  if (injected && !keep) injected.remove();
  if (!onDetail || store || keep) return;
  // Anchor on the visible title, not the first <h1> (that can be a dead view).
  const h1 = [...document.querySelectorAll('h1')].find(el => el.offsetHeight > 0);
  if (!h1) return; // header not rendered yet; the next mutation tick retries
  const btn = document.createElement('button');
  btn.className = 'vd-install';
  btn.textContent = 'Add to Safari';
  btn.style.cssText = VD_BTN_CSS;
  h1.insertAdjacentElement('afterend', btn);
  // An install is running for this page and the SPA dropped the node that was
  // showing progress — the fresh button becomes the progress card.
  if (installState && window.location.pathname === installState.path) renderProgress(btn);
}

function enableInstallButton() {
  const buttons = document.querySelectorAll('button, [role="button"], a');
  for (const btn of buttons) {
    // Already showing install progress — leave it alone.
    if (btn.dataset.vdProgress) continue;

    // textContent (not innerText) so disabled/greyed buttons still match.
    const text = (btn.textContent || '').toLowerCase().trim();
    const targetPhrases = ['available on chrome', 'add to chrome', 'get chrome'];

    if (targetPhrases.some(phrase => text.includes(phrase))) {
      // An install is running for THIS page and the SPA re-rendered the button
      // back to its Chrome label — re-adopt it as the progress card.
      if (installState && window.location.pathname === installState.path) {
        renderProgress(btn);
        continue;
      }

      // Re-enable disabled buttons
      if (btn.hasAttribute('disabled')) {
        btn.removeAttribute('disabled');
      }
      btn.style.pointerEvents = 'auto';

      // Paint it the app's brand teal so the repurposed button reads as "ours",
      // not Google's. setProperty(..., 'important') beats the store's own rules.
      btn.style.setProperty('background', '#4A9DAD', 'important');
      btn.style.setProperty('color', '#0A1A1E', 'important');
      btn.style.setProperty('border-color', '#4A9DAD', 'important');

      // Deep replace text nodes to preserve Google's button structure (spans, svgs).
      // No persistent flag: on SPA navigation Google reuses the same button node and
      // resets its text to "Add to Chrome", so we must relabel whenever a Chrome
      // phrase is present, not just the first time we see the node.
      const changeText = (el) => {
        for (const child of el.childNodes) {
          if (child.nodeType === Node.TEXT_NODE) {
            const lower = child.nodeValue.toLowerCase().trim();
            if (targetPhrases.some(p => lower.includes(p))) {
              child.nodeValue = 'Add to Safari';
            }
          } else if (child.nodeType === Node.ELEMENT_NODE) {
            // Inherit the teal text color over Google's per-span colors.
            child.style.setProperty('color', '#0A1A1E', 'important');
            changeText(child);
          }
        }
      };
      changeText(btn);
    }
  }
}

// The store is an SPA: it swaps page content via the History API without a full reload.
// We run on every store page (run_at document_start, so document.body may not exist yet)
// and keep a MutationObserver live for the whole session so client-side navigations are
// handled without a manual reload.
function apply() {
  enableInstallButton();
  ensureInstallButton();
  removeChromePromos();
}

function start() {
  apply();
  // Content scripts run in an isolated world, so we can't hook the page's history.pushState
  // to catch SPA navigations. The MutationObserver is the reliable signal: every client-side
  // route change swaps DOM nodes, which fires this. It stays live for the whole session, so
  // navigating into an extension without a reload is handled. popstate covers back/forward.
  new MutationObserver(apply).observe(document.documentElement, { childList: true, subtree: true });
  window.addEventListener('popstate', apply);
}

if (document.body) {
  start();
} else {
  document.addEventListener('DOMContentLoaded', start, { once: true });
}

document.addEventListener('click', (e) => {
  const btn = e.target.closest('button, [role="button"], a');
  if (!btn || btn.dataset.vdProgress) return;

  const text = (btn.textContent || '').toLowerCase().trim();
  const clickPhrases = ['add to safari', 'available on chrome', 'add to chrome', 'get chrome'];
  
  if (clickPhrases.some(phrase => text.includes(phrase))) {
    // Store URL is /detail/<slug>/<id>. Capture both: the slug names the app so
    // it isn't named after the random-looking id. Prefer the page's real <h1>
    // title; fall back to de-slugifying the URL segment.
    const match = window.location.pathname.match(/\/detail\/([^/]+)\/([a-z]{32})/);
    if (match) {
        e.preventDefault();
        e.stopPropagation();
        // The store sets <title> to "<Extension Name> - Chrome Web Store" for the
        // current page — reliable, unlike querySelector('h1') which can grab a
        // featured/related listing. De-slugged URL segment is the fallback.
        const fromTitle = document.title
          .replace(/\s*[-–|]\s*Chrome Web Store\s*$/i, '')
          .trim();
        const fromSlug = decodeURIComponent(match[1])
          .replace(/-/g, ' ')
          .replace(/\b\w/g, c => c.toUpperCase());
        installViaduct(match[2], fromTitle || fromSlug, btn);
    }
  }
}, true);

// ---- In-place install progress card ---------------------------------------
// The Viaduct app runs the conversion hidden; we poll it (content -> background
// -> native handler -> app) and render a progress card IN PLACE of the install
// button. The store SPA can re-render the button node mid-install, so all state
// lives in `installState` and enableInstallButton() re-adopts any reset button.

let installState = null; // { path, title, sub, fraction, color }
let pollGen = 0; // bumping cancels any in-flight polling loop
// Original button markup, saved before we replace it with the progress card.
// Restoring innerHTML (not textContent) keeps Google's font-bearing spans, so
// the button doesn't fall back to a generic font after dismissal.
const origMarkup = new WeakMap();

function renderProgress(btn) {
  if (!installState) return;
  btn.dataset.vdProgress = '1';
  if (btn.hasAttribute('disabled')) btn.removeAttribute('disabled');
  // Let the button grow into a card: the store gives it a fixed pill height.
  btn.style.setProperty('background', '#0A1A1E', 'important');
  btn.style.setProperty('border-color', '#0A1A1E', 'important');
  btn.style.setProperty('height', 'auto', 'important');
  btn.style.setProperty('min-height', '0', 'important');
  btn.style.setProperty('max-width', 'none', 'important');
  btn.style.setProperty('border-radius', '14px', 'important');
  btn.style.setProperty('box-shadow', '0 8px 30px rgba(0,0,0,.35)', 'important');
  btn.style.pointerEvents = 'none';

  let box = btn.querySelector('.vd-box');
  if (!box) {
    if (!origMarkup.has(btn)) origMarkup.set(btn, btn.innerHTML);
    btn.textContent = '';
    box = document.createElement('span');
    box.className = 'vd-box';
    box.style.cssText =
      'display:flex;flex-direction:column;align-items:stretch;text-align:left;' +
      'width:340px;max-width:75vw;padding:14px 18px;' +
      'font:13px/1.4 -apple-system,BlinkMacSystemFont,sans-serif';
    box.innerHTML =
      '<span style="display:flex;justify-content:space-between;align-items:baseline">' +
      '<span class="vd-title" style="color:#fff;font-weight:600;font-size:15px;line-height:1.3"></span>' +
      '<span class="vd-close" style="pointer-events:auto;cursor:pointer;' +
      'color:rgba(255,255,255,.6);font-size:13px;padding:0 2px">✕</span></span>' +
      '<span class="vd-sub" style="color:rgba(255,255,255,.65);font-size:13px;' +
      'line-height:1.35;display:block;margin:2px 0 10px;min-height:1em"></span>' +
      '<span style="background:rgba(255,255,255,.15);border-radius:99px;height:6px;' +
      'overflow:hidden;display:block">' +
      '<span class="vd-bar" style="background:#4A9DAD;height:100%;width:4%;display:block;' +
      'border-radius:99px;transition:width .6s ease"></span></span>';
    btn.appendChild(box);
    box.querySelector('.vd-close').addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      dismissProgress();
    });
  }
  box.querySelector('.vd-title').textContent = installState.title;
  const sub = box.querySelector('.vd-sub');
  sub.textContent = installState.sub || '';
  sub.title = installState.sub || '';
  const bar = box.querySelector('.vd-bar');
  bar.style.width = `${Math.round(installState.fraction * 100)}%`;
  bar.style.background = installState.color;
}

// Put the button back to its "Add to Safari" self (✕ clicked).
function dismissProgress() {
  stopProgressPolling();
  installState = null;
  document.querySelectorAll('[data-vd-progress]').forEach((btn) => {
    delete btn.dataset.vdProgress;
    btn.style.cssText = '';
    const saved = origMarkup.get(btn);
    if (saved != null) {
      // Google's own spans back in place — original font included. The saved
      // markup already reads "Add to Safari" (we relabel before any click).
      btn.innerHTML = saved;
      origMarkup.delete(btn);
    } else {
      // SPA replaced the node mid-install; no saved markup for this one.
      btn.textContent = 'Add to Safari';
    }
    if (btn.classList.contains('vd-install')) {
      // Our injected button has no store CSS classes — inline styles are all
      // it has, and the cssText reset above just wiped them.
      btn.style.cssText = VD_BTN_CSS;
      return;
    }
    btn.style.pointerEvents = 'auto';
    btn.style.setProperty('background', '#4A9DAD', 'important');
    btn.style.setProperty('color', '#0A1A1E', 'important');
    btn.style.setProperty('border-color', '#4A9DAD', 'important');
  });
}

function setState(title, sub, fraction, color) {
  installState = { ...installState, title, sub, fraction, color };
  document.querySelectorAll('[data-vd-progress]').forEach(renderProgress);
  // Adopt any freshly re-rendered (unmarked) button too.
  enableInstallButton();
}

function stopProgressPolling() {
  pollGen++;
}

function startProgressPolling(btn) {
  const gen = ++pollGen;
  installState = { path: window.location.pathname };
  setState('Contacting Viaduct…', 'Launching the converter', 0.04, '#4A9DAD');
  if (btn) renderProgress(btn);
  const startedAt = Date.now();
  // Terminal states can be stale leftovers from a previous run (the app keeps
  // its last phase until the new install resets it), so ignore done/failed
  // until we've seen this run actually working.
  let sawActivity = false;
  let lastError = '';

  // Sequential loop, not setInterval: the native handler is spawned cold for
  // every poll and can take well over a second end to end. Overlapping ticks
  // with a tight race timeout read as "unreachable" even when the chain works.
  const tick = async () => {
    if (gen !== pollGen) return;
    let state = null;
    try {
      // Race a timeout: if anything along content -> background -> native ->
      // app stalls, sendMessage's promise may never settle, and an await with
      // no timeout would wedge the loop at "Contacting…" forever.
      const req = browser.runtime.sendMessage({ type: 'viaduct-progress' });
      req.catch(() => {});
      state = await Promise.race([
        req,
        new Promise(resolve => setTimeout(() => resolve(null), 2500)),
      ]);
    } catch (e) { /* background asleep; try next tick */ }
    if (gen !== pollGen) return;
    const s = state && state.state;
    if (state && state.error) lastError = state.error;
    const elapsed = Date.now() - startedAt;

    if (s === 'active') {
      sawActivity = true;
      setState(state.title || 'Converting…', state.subtitle || '',
               Math.max(0.04, state.fraction || 0), '#4A9DAD');
    } else if (s === 'done' && sawActivity) {
      setState('Installed ✓', 'Enable it in Safari → Settings → Extensions', 1, '#4A9DAD');
      return;
    } else if (s === 'failed' && (sawActivity || elapsed > 10000)) {
      setState('Install failed', state.message || 'Open Viaduct for details.', 1, '#F87171');
      return;
    } else if (!sawActivity && elapsed > 30000) {
      setState('Install failed',
               lastError ? `Couldn't reach Viaduct: ${lastError}`
                         : "Couldn't reach Viaduct — open the app to see what happened.",
               1, '#F87171');
      return;
    } else if (elapsed > 20 * 60 * 1000) {
      setState('Still working…',
               'Taking unusually long — open Viaduct to check on it.', 1, '#FBBF24');
      return;
    }
    setTimeout(tick, 800);
  };
  tick();
}
