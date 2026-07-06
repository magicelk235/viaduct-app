// Relay: content scripts can't call sendNativeMessage in Safari, so progress
// polls route through here to the native SafariWebExtensionHandler.
// sendResponse + `return true` (not a returned Promise) — Safari resolves the
// content script's sendMessage() only via sendResponse; a returned Promise can
// leave the caller's await hanging forever.
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.type === 'viaduct-progress') {
    browser.runtime
      .sendNativeMessage('com.magicelk235.viaduct.Extension', { type: 'progress' })
      .then(sendResponse, () => sendResponse({ state: 'unreachable' }));
    return true;
  }
});
