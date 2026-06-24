function installViaduct(extId, name) {
  let url = `viaduct://install?id=${extId}`;
  if (name) url += `&name=${encodeURIComponent(name)}`;
  window.location.href = url;
}

function enableInstallButton() {
  const buttons = document.querySelectorAll('button, [role="button"], a');
  for (const btn of buttons) {
    const text = (btn.innerText || '').toLowerCase().trim();
    const targetPhrases = ['available on chrome', 'add to chrome', 'get chrome'];
    
    if (targetPhrases.some(phrase => text.includes(phrase))) {
      // Re-enable disabled buttons
      if (btn.hasAttribute('disabled')) {
        btn.removeAttribute('disabled');
      }
      btn.style.pointerEvents = 'auto';
      
      // Change the label
      if (!btn.dataset.viaductEnabled) {
        btn.dataset.viaductEnabled = 'true';
        
        // Deep replace text nodes to preserve Google's button structure (spans, svgs)
        const changeText = (el) => {
          for (const child of el.childNodes) {
            if (child.nodeType === Node.TEXT_NODE) {
              const lower = child.nodeValue.toLowerCase().trim();
              if (targetPhrases.some(p => lower.includes(p))) {
                child.nodeValue = 'Add to Safari';
              }
            } else if (child.nodeType === Node.ELEMENT_NODE) {
              changeText(child);
            }
          }
        };
        changeText(btn);
      }
    }
  }
}

// Run immediately and observe DOM changes (since the store is an SPA)
enableInstallButton();
const observer = new MutationObserver(() => enableInstallButton());
observer.observe(document.body, { childList: true, subtree: true });

document.addEventListener('click', (e) => {
  const btn = e.target.closest('button, [role="button"], a');
  if (!btn) return;
  
  const text = (btn.innerText || '').toLowerCase().trim();
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
