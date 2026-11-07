// Shared by every page: creates the Supabase client, shows or hides role-gated
// nav links, fills the login item, and marks the current page as active.
(function () {
  var CFG = window.AUTH_CONFIG;

  // Supabase comes from a CDN that ad blockers and school filters can block. Public pages work
  // without it; the app pages would otherwise hang, so tell the person what happened.
  if (!window.supabase) {
    if (/\/(1307scout|account|alliance|portal|query|scout|signin)(\.html)?$/.test(location.pathname)) {
      var note = document.createElement("div");
      note.className = "alert alert-danger";
      note.style.cssText = "margin:6rem 1rem 1rem;";
      note.setAttribute("role", "alert");
      note.textContent = "1307scout couldn't load its sign-in service. Check your connection, " +
        "turn off any ad blocker for this site, or try a different network, then refresh.";
      document.body.insertBefore(note, document.body.firstChild);
    }
    return;
  }

  // Read this before createClient: the client clears the URL hash once it has read the tokens.
  var recovery = /type=recovery/.test(location.hash);
  var sb = window.supabase.createClient(CFG.url, CFG.anonKey);

  // supabase-js reports a network failure as a returned error and keeps the session, which on a
  // shared computer would leave the next person signed in. Sign-out must always clear this device.
  async function signOut(opts) {
    var failed;
    try { failed = !!(await sb.auth.signOut(opts)).error; } catch (e) { failed = true; }
    if (!failed) return;
    Object.keys(localStorage).forEach(function (k) {
      if (/^sb-.*-auth-token/.test(k)) localStorage.removeItem(k);
    });
  }

  window.RS = { sb: sb, recovery: recovery, signOut: signOut };

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

  sb.auth.getSession().then(function (r) {
    var session = r.data.session;
    if (!session) return renderNav(null, "guest");
    return sb.rpc("my_access_level").then(function (res) {
      renderNav(session, (res && res.data) || "guest");
    });
  });
})();