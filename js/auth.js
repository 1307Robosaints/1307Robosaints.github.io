// Shared by every page: creates the Supabase client, shows or hides role-gated
// nav links, fills the login item, and marks the current page as active.
(function () {
  var CFG = window.AUTH_CONFIG;

  // GitHub Pages can't send X-Frame-Options, so refuse to run inside another site's frame
  // (clickjacking the Staff Portal's buttons). Only on the live site, so local previews still work.
  if (window.top !== window.self && /(^|\.)robosaints1307\.com$/.test(location.hostname)) {
    document.documentElement.style.display = "none";
    try { window.top.location.replace(location.href); } catch (e) {}
    return;
  }

  // Release info, put in by deploy/build.sh (absent locally): the version goes in the footer, and
  // the experimental site gets a bar saying so, with a link to the stable one. See RELEASING.md.
  var BUILD = window.RS_BUILD;
  if (BUILD && BUILD.site !== "info") {
    document.addEventListener("DOMContentLoaded", function () {
      var foot = document.querySelector("#bottomrow .container");
      if (foot) {
        var v = document.createElement("p");
        v.className = "m-0 mt-2 text-center";
        v.style.cssText = "font-size:.72rem;opacity:.75;color:#fff;";
        v.textContent = "1307scout " + (BUILD.channel === "experimental" ? "experimental " : "v") + BUILD.version;
        foot.appendChild(v);
      }
      if (BUILD.channel === "experimental") {
        var bar = document.createElement("div");
        bar.setAttribute("role", "note");
        bar.style.cssText = "position:fixed;left:0;right:0;bottom:0;z-index:2000;padding:.2rem .75rem;" +
          "font-size:.75rem;text-align:center;background:#B45309;color:#fff;";
        bar.innerHTML = "Experimental 1307scout: new features being tried out, on the real data. " +
          "<a href=\"https://scout.robosaints1307.com" + location.pathname.replace(/"/g, "") +
          "\" style=\"color:#fff;text-decoration:underline;\">Use the stable version</a>";
        document.body.appendChild(bar);
        document.body.style.paddingBottom = "1.6rem";
      }
    });
  }

  // A banner for problems that stop an app page from working
  function showNote(text) {
    var note = document.createElement("div");
    note.className = "alert alert-danger";
    note.style.cssText = "margin:6rem 1rem 1rem;";
    note.setAttribute("role", "alert");
    note.textContent = text;
    document.body.insertBefore(note, document.body.firstChild);
  }

  // Supabase comes from a CDN that ad blockers and school filters can block. Public pages work
  // without it; the app pages would otherwise hang, so tell the person what happened.
  if (!window.supabase) {
    if (/\/(1307scout|account|alliance|bracket|flags|matches|picklist|pitcrew|playoffs|portal|query|scout|shifts|signin|strategy)(\.html)?$/.test(location.pathname)) {
      showNote("1307scout couldn't load its sign-in service. Check your connection, " +
        "turn off any ad blocker for this site, or try a different network, then refresh.");
    }
    return;
  }

  // Read this before createClient: the client clears the URL hash once it has read the tokens.
  var recovery = /type=recovery/.test(location.hash);
  var sb = window.supabase.createClient(CFG.url, CFG.anonKey);

  // supabase-js reports a network failure as a returned error and keeps the session, which on a
  // shared computer would leave the next person signed in. Sign-out must always clear this device.
  // The offline copies below (rs_level_*, rs_offline_*) go too. Unsent scouting drafts stay,
  // since they're kept per account and are sent the next time that person signs in here.
  async function signOut(opts) {
    var failed;
    try { failed = !!(await sb.auth.signOut(opts)).error; } catch (e) { failed = true; }
    Object.keys(localStorage).forEach(function (k) {
      if (/^rs_(level|offline)_/.test(k) || (failed && /^sb-.*-auth-token/.test(k))) localStorage.removeItem(k);
    });
  }

  // ── Offline (for the installed app, see js/pwa.js) ──
  // With no connection, supabase-js can't refresh an expired login and reports no session,
  // though the login is still saved on the device (a refresh token the server rejected would
  // have been deleted). session() falls back to that saved login so pages can open offline;
  // anything sent to the server still has to refresh it first, so this grants no access.
  function storedSession() {
    try {
      var k = Object.keys(localStorage).find(function (x) { return /^sb-.*-auth-token$/.test(x); });
      var s = k && JSON.parse(localStorage.getItem(k));
      return s && s.user && s.user.id ? s : null;
    } catch (e) { return null; }
  }
  // With an expired login and no connection, supabase-js keeps retrying the refresh for up to
  // 30 s, so when a saved login exists this stops waiting after a few seconds.
  function timeout(ms, value) {
    return new Promise(function (res) { setTimeout(function () { res(value); }, ms); });
  }
  async function session() {
    var saved = storedSession();
    if (saved && navigator.onLine === false) return saved;
    var r = saved ?await Promise.race([sb.auth.getSession(), timeout(6000, { data: {}, error: "timeout" })])
                  : await sb.auth.getSession();
    if (r.data.session) return r.data.session;
    return (r.error || navigator.onLine === false) ? saved : null;
  }
  // The last access level the server gave each account on this device. Only used to choose which
  // page to show while offline: the database still checks every read and write.
  function rememberLevel(level) {
    var s = storedSession();
    try { if (s) localStorage.setItem("rs_level_" + s.user.id, level); } catch (e) {}
  }
  function savedLevel() {
    var s = storedSession();
    try { return s ? localStorage.getItem("rs_level_" + s.user.id) : null; } catch (e) { return null; }
  }

  // The access level, or null after showing a banner if the server can't be reached. Pages must
  // stop on null: treating it as "guest" would send a scout on a bad connection to the wrong page.
  // One my_access_level request per page load, shared by the nav and the page. A failed one isn't
  // kept, so a later call can try again.
  var levelReq = null;
  function levelRequest() {
    if (!levelReq) {
      levelReq = sb.rpc("my_access_level").then(function (r) {
        if (r.error) levelReq = null;
        else rememberLevel(r.data || "guest");
        return r;
      }, function (e) {
        levelReq = null;
        return { error: e };
      });
    }
    return levelReq;
  }
  // Pages that work offline pass { offline: true } to get the saved level when the server can't be reached.
  async function accessLevel(opts) {
    var saved = opts && opts.offline && savedLevel();
    var r = navigator.onLine === false ? { error: "offline" }
          : saved ? await Promise.race([levelRequest(), timeout(6000, { error: "timeout" })])
          : await levelRequest();
    if (r.error) {
      if (saved) return saved;
      showNote(navigator.onLine === false
        ? "You're offline, and this page needs a connection. The Scout page still works offline."
        : "Couldn't reach 1307scout to check your access. Check your connection, then refresh.");
      return null;
    }
    return r.data || "guest";
  }

  window.RS = { sb: sb, recovery: recovery, signOut: signOut, accessLevel: accessLevel, session: session };

  // Highlight the current page's link. Dropdown toggles use href="#", so skip anything that isn't a real page.
  function markActive() {
    var here = location.pathname.replace(/\/+$/, "") || "/index.html";
    document.querySelectorAll("#navbarResponsive a[href]").forEach(function (a) {
      var href = a.getAttribute("href");
      if (!href || href.charAt(0) === "#") return;
      var target = new URL(href, location.href).pathname.replace(/\/+$/, "") || "/index.html";
      if (target !== here) return;
      a.classList.add("active");
      a.setAttribute("aria-current", "page");
      var dd = a.closest(".dropdown");
      if (dd) dd.querySelector(".dropdown-toggle").classList.add("active");
    });
    // 1307scout pages left out of the short menu still highlight it
    var scoutToggle = document.getElementById("navScout");
    if (scoutToggle && /\/(flags|ratings|shifts|picklist|pitcrew)(\.html)?$/.test(here)) scoutToggle.classList.add("active");
  }

  function renderNav(session, level) {
    var authItem = document.getElementById("authNavItem");
    if (authItem) {
      var a = authItem.querySelector("a");
      a.href = session ? "/account.html" : "/signin.html";
      a.textContent = session ? "My Account" : "Sign In";
    }
    document.querySelectorAll("[data-role]").forEach(function (el) {
      var role = el.getAttribute("data-role");
      var show = role === "staff" ? level === "staff"
               : role === "team"  ? (level === "staff" || level === "student")
               : false;
      el.hidden = !show;
    });
    markActive();
  }

  renderNav(null, "guest");   // hide team and staff links until we know who is signed in

  // Offline, the menu uses the saved login and level, so the installed app still links to Scout
  session().then(function (s) {
    if (!s) return renderNav(null, "guest");
    // The theme saved to the account on My Account follows the person to this device (js/theme.js)
    if (window.RSTheme && s.user.user_metadata) RSTheme.fromAccount(s.user.user_metadata.theme);
    if (navigator.onLine === false) return renderNav(s, savedLevel() || "guest");
    return levelRequest().then(function (res) {
      renderNav(s, res.error ? (savedLevel() || "guest") : (res.data || "guest"));
    });
  });
})();