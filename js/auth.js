// Shared by every page: creates the Supabase client, sets up the navbar's
// login item and role-gated links, and marks the current page as active.
(function () {
  var CFG = window.AUTH_CONFIG;
  var sb = window.supabase.createClient(CFG.url, CFG.anonKey);

  window.RS = {
    sb: sb,
    isMember: function (u) {
      return !!u && !!u.email_confirmed_at &&
             u.email.toLowerCase().endsWith("@" + CFG.memberDomain);
    }
  };

  // Mark the link for the current page as active
  function markActive() {
    var here = location.pathname.replace(/\/+$/, "") || "/index.html";
    document.querySelectorAll("#navbarResponsive .nav-link[href]").forEach(function (a) {
      var target = new URL(a.getAttribute("href"), location.href).pathname;
      if (target === here || (here === "/" && target === "/index.html")) {
        a.classList.add("active");
        var parentDropdown = a.closest(".dropdown");
        if (parentDropdown) parentDropdown.querySelector(".dropdown-toggle").classList.add("active");
      }
    });
  }

  // Show/hide role-gated links and fill the login item
  function renderNav(session, level) {
    var loggedIn = !!session;
    var authItem = document.getElementById("authNavItem");
    if (authItem) {
      var a = authItem.querySelector("a");
      a.href = loggedIn ? "/account.html" : "/signin.html";
      a.textContent = loggedIn ? "My Account" : "Sign In";
    }
    document.querySelectorAll("[data-role]").forEach(function (li) {
      var role = li.getAttribute("data-role");
      var show = role === "staff" ? level === "staff"
               : role === "team"  ? (level === "staff" || level === "student")
               : false;
      li.hidden = !show;
    });
  }

  markActive();

  sb.auth.getSession().then(function (r) {
    var session = r.data.session;
    if (!session) return renderNav(null, "guest");
    sb.rpc("my_access_level").then(function (res) {
      renderNav(session, (res && res.data) || "guest");
    });
  });
})();