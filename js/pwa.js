// Shared by every page: the 1307scout app (PWA). Registers the service worker (/sw.js), adds
// "Get the app" to the 1307scout menu, shows a notice while offline, and wires up install buttons.
//
// Markup any page can use (app.html, 1307scout.html and account.html do):
//   [data-app-install]          a button that opens the browser's install prompt. Hidden until the
//                               browser offers one (Chrome, Edge, Android); Safari and Firefox don't.
//   [data-app-when="installed"] shown only inside the installed app
//   [data-app-when="browser"]   shown only in a normal browser tab
//   [data-app-device="ios"]     marked .app-this-device when it matches the visitor's device
//                               (ios, android, windows, mac, chromebook, linux)
// window.RSApp has the same information for scripts.
(function () {
  var promptEvent = null;

  function installed() {
    return (window.matchMedia && matchMedia("(display-mode: standalone)").matches) ||
      (window.matchMedia && matchMedia("(display-mode: window-controls-overlay)").matches) ||
      navigator.standalone === true;   // iOS home-screen apps
  }

  // Best guess at the visitor's device, for showing the right install steps first
  function device() {
    var ua = navigator.userAgent;
    if (/iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return "ios";
    if (/Android/.test(ua)) return "android";
    if (/CrOS/.test(ua)) return "chromebook";
    if (/Windows/.test(ua)) return "windows";
    if (/Macintosh/.test(ua)) return "mac";
    if (/Linux/.test(ua)) return "linux";
    return "other";
  }

  // The install prompt; resolves true if the person accepted it
  function install() {
    if (!promptEvent) return Promise.resolve(false);
    var ev = promptEvent;
    promptEvent = null;
    ev.prompt();
    return ev.userChoice.then(function (c) { refresh(); return c.outcome === "accepted"; },
                              function () { refresh(); return false; });
  }

  window.RSApp = {
    installed: installed,
    device: device,
    canPrompt: function () { return !!promptEvent; },
    install: install
  };

  // Show, hide and mark the app elements on the page to match the current state
  function refresh() {
    var inApp = installed(), dev = device();
    document.querySelectorAll("[data-app-install]").forEach(function (b) {
      b.hidden = inApp || !promptEvent;
    });
    document.querySelectorAll("[data-app-when]").forEach(function (el) {
      el.hidden = (el.getAttribute("data-app-when") === "installed") !== inApp;
    });
    document.querySelectorAll("[data-app-device]").forEach(function (el) {
      var list = el.getAttribute("data-app-device").split(/\s+/);
      el.classList.toggle("app-this-device", list.indexOf(dev) !== -1);
    });
    var navItem = document.getElementById("navGetApp");
    if (navItem) navItem.hidden = inApp;
    document.dispatchEvent(new CustomEvent("rsapp:change"));
  }

  // Chrome, Edge and Android fire this when the site can be installed
  window.addEventListener("beforeinstallprompt", function (e) {
    e.preventDefault();      // keep the prompt for our own Install buttons
    promptEvent = e;
    refresh();
  });
  window.addEventListener("appinstalled", function () { promptEvent = null; refresh(); });

  // Install buttons open the browser's prompt
  document.addEventListener("click", function (e) {
    var btn = e.target.closest && e.target.closest("[data-app-install]");
    if (btn) { e.preventDefault(); install(); }
  });

  // "Get the app", right after "1307scout Home" in the menu, so it's on every page
  function addNavLink() {
    var home = document.querySelector('#navbarResponsive .dropdown-menu a[href="/1307scout.html"]');
    if (!home || document.getElementById("navGetApp")) return;
    var a = document.createElement("a");
    a.className = "dropdown-item";
    a.id = "navGetApp";
    a.href = "/app.html";
    a.textContent = "Get the app";
    home.insertAdjacentElement("afterend", a);
    if (/\/app(\.html)?$/.test(location.pathname)) a.classList.add("active");
  }

  // A small notice in the corner while there's no connection
  function addOfflineNotice() {
    var style = document.createElement("style");
    // Page styles like .hero-cta/.btn set display, which would override the hidden attribute
    style.textContent =
      "[data-app-install][hidden],[data-app-when][hidden]{display:none!important}" +
      ".app-offline{position:fixed;left:1rem;bottom:1rem;z-index:1080;max-width:calc(100% - 2rem);" +
      "background:#0A2352;color:#fff;font-size:.82rem;padding:.5rem .8rem;border-left:3px solid #f0ad4e;" +
      "box-shadow:0 4px 14px rgba(0,0,0,.25)}" +
      ".app-this-device{outline:2px solid #1B4DB1;outline-offset:2px}";
    document.head.appendChild(style);
    var note = document.createElement("div");
    note.className = "app-offline";
    note.setAttribute("role", "status");
    note.hidden = true;
    note.textContent = "You're offline. Saved pages still open, and new match entries wait on this device until you reconnect.";
    document.body.appendChild(note);
    function update() { note.hidden = navigator.onLine !== false; }
    window.addEventListener("online", update);
    window.addEventListener("offline", update);
    update();
  }

  function start() {
    addNavLink();
    addOfflineNotice();
    refresh();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();

  // Service workers need https (or localhost for testing)
  if (!("serviceWorker" in navigator) || !window.isSecureContext) return;

  window.addEventListener("load", function () {
    navigator.serviceWorker.register("/sw.js").catch(function (e) {
      console.warn("1307scout app: service worker not registered", e);
    });
    // The CDN libraries and fonts this page loaded before the worker was running, so they're
    // saved for offline use too. The worker ignores anything that isn't on its CDN list.
    navigator.serviceWorker.ready.then(function (reg) {
      if (!reg.active || !window.performance || !performance.getEntriesByType) return;
      var urls = performance.getEntriesByType("resource").map(function (r) { return r.name; })
        .filter(function (u) { return /^https:\/\//.test(u) && u.indexOf(location.origin) !== 0; });
      if (urls.length) reg.active.postMessage({ type: "save", urls: urls });
    });
    // Ask the browser not to clear this site's storage (offline drafts live there). Installed
    // apps usually get this automatically; in a browser tab it may quietly be refused.
    if (installed() && navigator.storage && navigator.storage.persist) {
      navigator.storage.persist().catch(function () {});
    }
  });
})();
