// Light / dark theme. Loaded in every page's <head>, before the stylesheets, so a dark page never
// flashes white. The choice ("light", "dark" or "system" to match the device) is made on My Account,
// kept on this device in a cookie shared by every robosaints1307.com subdomain (the info site, 1307scout
// and beta are separate origins, so localStorage alone made each one keep its own theme), with
// localStorage (rs_theme) as the fallback, and also saved to the account by account.html so it
// follows the person to other devices (auth.js applies it after sign-in). Default is light.
// css/modern.css does the rest from <html data-theme="...">.
(function () {
  var KEY = "rs_theme";
  var root = document.documentElement;
  // Cookie on the parent domain on the live sites, host-only elsewhere (local files, localhost)
  var host = location.hostname, DOMAIN = /(^|\.)robosaints1307\.com$/.test(host) ? "; domain=robosaints1307.com" : "";
  function get(k) {
    var m = document.cookie.match(new RegExp("(?:^|; )" + k + "=([^;]*)"));
    if (m) return m[1];
    try { return localStorage.getItem(k); } catch (e) { return null; }
  }
  function put(k, v) {
    try {
      document.cookie = k + "=" + v + "; path=/; max-age=31536000; samesite=lax" + DOMAIN +
        (location.protocol === "https:" ? "; secure" : "");
    } catch (e) {}
    try { localStorage.setItem(k, v); } catch (e) {}
  }
  var mq = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  function choice() {
    var v = get(KEY);
    return v === "dark" || v === "system" ? v : "light";
  }
  function resolved(c) { return c === "dark" || (c === "system" && mq && mq.matches) ? "dark" : "light"; }

  // Images with a dark-theme copy name it in data-dark-src (the team's logos, see img/)
  function swapImages(theme) {
    document.querySelectorAll("img[data-dark-src]").forEach(function (img) {
      if (!img.hasAttribute("data-light-src")) img.setAttribute("data-light-src", img.getAttribute("src"));
      var want = img.getAttribute(theme === "dark" ? "data-dark-src" : "data-light-src");
      if (img.getAttribute("src") !== want) img.setAttribute("src", want);
    });
  }

  function apply() {
    var theme = resolved(choice());
    root.setAttribute("data-theme", theme);
    swapImages(theme);
  }

  // Saves the choice on this device and applies it. Unknown values fall back to light.
  function set(c) {
    c = c === "dark" || c === "system" ? c : "light";
    put(KEY, c);
    apply();
    document.dispatchEvent(new CustomEvent("rs-theme", { detail: c }));   // lets My Account update its switch
    return c;
  }

  // A choice saved only in localStorage (before the shared cookie) moves into the cookie
  if (!/(?:^|; )rs_theme=/.test(document.cookie)) { var old = get(KEY); if (old) put(KEY, old); }

  apply();
  window.addEventListener("pageshow", apply);   // back/forward from another subdomain restores a cached page
  document.addEventListener("DOMContentLoaded", apply);                // images now exist
  if (mq && mq.addEventListener) mq.addEventListener("change", apply); // device switched, for "system"
  else if (mq && mq.addListener) mq.addListener(apply);                // older Safari
  window.addEventListener("storage", function (e) { if (e.key === KEY) apply(); });   // other tabs

  // The account's saved theme (user_metadata.theme), passed in by auth.js after sign-in. It's applied
  // only when it changed since this device last saw it (rs_theme_acct), so a choice made here that
  // couldn't reach the server yet isn't undone on the next page.
  var ACCT = "rs_theme_acct";
  function seen(v) { put(ACCT, v); }
  function fromAccount(v) {
    if (v !== "light" && v !== "dark" && v !== "system") return;
    var last = get(ACCT);
    if (v === last) return;
    seen(v);
    if (v !== choice()) set(v);
  }

  window.RSTheme = {
    choice: choice, set: set, fromAccount: fromAccount,
    savedToAccount: seen,                                // account.html, after saving the choice
    current: function () { return resolved(choice()); }
  };
})();
