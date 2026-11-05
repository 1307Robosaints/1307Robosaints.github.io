// Shared by every page: creates the Supabase client, shows or hides role-gated
// nav links, fills the login item, and marks the current page as active.
(function () {
  var CFG = window.AUTH_CONFIG;
  var sb = window.supabase.createClient(CFG.url, CFG.anonKey);
  window.RS = { sb: sb };

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