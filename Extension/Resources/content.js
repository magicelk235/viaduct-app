function installViaduct(extId) {
  window.location.href = `viaduct://install?id=${extId}`;
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
    const match = window.location.pathname.match(/\/detail\/[^/]+\/([a-z]{32})/);
    if (match) {
        e.preventDefault();
        e.stopPropagation();
        installViaduct(match[1]);
    }
  }
}, true);
