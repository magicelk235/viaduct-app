// sidepanel-inject.js — content script that fakes a Chrome side panel in Safari.
// Safari has no native extension side panel, so we inject the extension's own
// sidepanel.html in an extension-origin iframe docked to the right edge, shift
// the page over so nothing is covered, and toggle it on toolbar-button clicks
// (the background relays action.onClicked → a "c2s-toggle-sidepanel" message).
(function () {
  if (window.__c2sSidepanelInstalled) return;
  window.__c2sSidepanelInstalled = true;

  var WIDTH = 400;                       // px; matches a Chrome side panel feel
  var PANEL_URL = (function () {
    try {
      var api = (typeof chrome !== "undefined" && chrome.runtime) ? chrome
              : (typeof browser !== "undefined" ? browser : null);
      return api && api.runtime && api.runtime.getURL
        ? api.runtime.getURL("sidepanel.html") : null;
    } catch (e) { return null; }
  })();

  var host = null;       // outer fixed container
  var iframe = null;
  var open = false;

  function build() {
    if (host || !PANEL_URL) return;

    host = document.createElement("div");
    host.id = "c2s-sidepanel-host";
    host.style.cssText = [
      "position:fixed", "top:0", "right:0", "height:100vh",
      "width:" + WIDTH + "px", "z-index:2147483647",
      "box-shadow:-2px 0 16px rgba(0,0,0,0.25)",
      "background:#fff", "transform:translateX(100%)",
      "transition:transform .22s cubic-bezier(.4,0,.2,1)",
      "display:flex", "flex-direction:column"
    ].join(";");

    // Slim drag handle on the left edge for resizing.
    var grip = document.createElement("div");
    grip.style.cssText = [
      "position:absolute", "left:0", "top:0", "height:100%", "width:6px",
      "cursor:col-resize", "z-index:1"
    ].join(";");
    grip.addEventListener("mousedown", startResize);

    iframe = document.createElement("iframe");
    iframe.src = PANEL_URL;
    iframe.style.cssText = [
      "border:0", "width:100%", "height:100%", "flex:1", "background:#fff"
    ].join(";");
    // Same extension origin → the sidepanel's own scripts/messaging run normally.
    iframe.setAttribute("allow", "clipboard-read; clipboard-write");

    host.appendChild(grip);
    host.appendChild(iframe);
    document.documentElement.appendChild(host);
  }

  function setOpen(next) {
    if (!PANEL_URL) return;
    build();
    open = next;
    host.style.transform = open ? "translateX(0)" : "translateX(100%)";
    // Push the page so the panel doesn't overlap content (Chrome docks/insets).
    document.documentElement.style.transition = "margin-right .22s cubic-bezier(.4,0,.2,1)";
    document.documentElement.style.marginRight = open ? (currentWidth() + "px") : "";
  }

  function currentWidth() {
    return host ? parseInt(host.style.width, 10) || WIDTH : WIDTH;
  }

  // --- resize ---
  var resizing = false, startX = 0, startW = 0;
  function startResize(e) {
    resizing = true; startX = e.clientX; startW = currentWidth();
    e.preventDefault();
    document.addEventListener("mousemove", onResize);
    document.addEventListener("mouseup", endResize);
  }
  function onResize(e) {
    if (!resizing) return;
    var w = Math.min(720, Math.max(280, startW + (startX - e.clientX)));
    host.style.width = w + "px";
    if (open) document.documentElement.style.marginRight = w + "px";
  }
  function endResize() {
    resizing = false;
    document.removeEventListener("mousemove", onResize);
    document.removeEventListener("mouseup", endResize);
  }

  // Toolbar button → background → here.
  function onMessage(msg) {
    if (!msg) return;
    if (msg.type === "c2s-toggle-sidepanel") setOpen(!open);
    else if (msg.type === "c2s-open-sidepanel") setOpen(true);
    else if (msg.type === "c2s-close-sidepanel") setOpen(false);
  }
  try {
    var rt = (typeof chrome !== "undefined" && chrome.runtime) ? chrome.runtime
           : (typeof browser !== "undefined" ? browser.runtime : null);
    if (rt && rt.onMessage) rt.onMessage.addListener(onMessage);
  } catch (e) {}

  // Let the sidepanel iframe ask its host to close (postMessage from inside).
  window.addEventListener("message", function (ev) {
    var d = ev.data;
    if (d && d.__c2sSidepanel === "close") setOpen(false);
  });
})();
