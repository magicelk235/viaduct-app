function installViaduct(extId, name) {
  let url = `viaduct://install?id=${extId}`;
  if (name) url += `&name=${encodeURIComponent(name)}`;
  window.location.href = url;
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

function enableInstallButton() {
  const buttons = document.querySelectorAll('button, [role="button"], a');
  for (const btn of buttons) {
    // textContent (not innerText) so disabled/greyed buttons still match.
    const text = (btn.textContent || '').toLowerCase().trim();
    const targetPhrases = ['available on chrome', 'add to chrome', 'get chrome'];

    if (targetPhrases.some(phrase => text.includes(phrase))) {
      // Re-enable disabled buttons
      if (btn.hasAttribute('disabled')) {
        btn.removeAttribute('disabled');
      }
      btn.style.pointerEvents = 'auto';

      // Paint it the app's brand teal so the repurposed button reads as "ours",
      // not Google's. setProperty(..., 'important') beats the store's own rules.
      btn.style.setProperty('background', '#2DD4BF', 'important');
      btn.style.setProperty('color', '#04201C', 'important');
      btn.style.setProperty('border-color', '#2DD4BF', 'important');

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
            child.style.setProperty('color', '#04201C', 'important');
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
  if (!btn) return;
  
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
        installViaduct(match[2], fromTitle || fromSlug);
    }
  }
}, true);
