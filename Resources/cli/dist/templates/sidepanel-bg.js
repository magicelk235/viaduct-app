// sidepanel-bg.js — background relay for the injected Safari side panel.
// Safari has no native side panel, so the toolbar button can't open one
// directly. We turned the action into a plain click action; here we relay that
// click to the active tab's content script (sidepanel-inject.js), which toggles
// the docked iframe panel.
(function () {
  var api = (typeof chrome !== "undefined" && chrome.action) ? chrome
          : (typeof browser !== "undefined" ? browser : null);
  if (!api) return;
  var action = api.action || api.browserAction;
  if (!action || !action.onClicked || !action.onClicked.addListener) return;

  action.onClicked.addListener(function (tab) {
    if (!tab || tab.id == null) return;
    try {
      api.tabs.sendMessage(tab.id, { type: "c2s-toggle-sidepanel" }, function () {
        // Swallow "no receiving end" (e.g. on a page the content script can't run).
        void (api.runtime && api.runtime.lastError);
      });
    } catch (e) {}
  });
})();
