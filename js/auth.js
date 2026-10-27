// Shared by every page: creates the Supabase client and adds Sign in / My account to the navbar.
(function () {
  var CFG = window.AUTH_CONFIG;
  var sb = window.supabase.createClient(CFG.url, CFG.anonKey);
  window.RS = {
    sb: sb,
    isMember: function (u) {
      return !!u && !!u.email_confirmed_at && u.email.toLowerCase().endsWith("@" + CFG.memberDomain);
    }
  };
  sb.auth.getSession().then(function (r) {
    var list = document.querySelector("#navbarResponsive .navbar-nav");
    if (!list) return;
    var li = document.createElement("li");
    li.className = "nav-item";
    var a = document.createElement("a");
    a.className = "nav-link";
    a.href = r.data.session ? "account.html" : "signin.html";
    a.textContent = r.data.session ? "My Account" : "Sign In";
    li.appendChild(a);
    list.appendChild(li);
  });
})();
