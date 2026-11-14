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
    if (/\/(1307scout|account|alliance|bracket|flags|live|matches|picklist|pitcrew|playoffs|portal|query|scout|share|shifts|signin|strategy|team)(\.html)?$/.test(location.pathname)) {
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
  // The offline copies below (rs_level_*, rs_team_*, rs_offline_*) go too. Unsent scouting drafts stay,
  // since they're kept per account and are sent the next time that person signs in here.
  async function signOut(opts) {
    var failed;
    try { failed = !!(await sb.auth.signOut(opts)).error; } catch (e) { failed = true; }
    Object.keys(localStorage).forEach(function (k) {
      if (/^rs_(level|offline|team)_/.test(k) || (failed && /^sb-.*-auth-token/.test(k))) localStorage.removeItem(k);
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

  // The signed-in person's team, from my_team_info() (SQL section 3b): { team_number, role
  // ('manager' or 'member'), name, settings, can: { strategy, pit_crew, pick_list, scout_shifts },
  // request }. team_number is null for someone on no team. One request per page load, and the last
  // answer is kept on the device for offline use; null if neither is available. The database still
  // checks every read and write, so this only decides what a page shows.
  var teamReq = null;
  function team() {
    var s = storedSession(), key = s && "rs_team_" + s.user.id;
    function saved() { try { return key ? JSON.parse(localStorage.getItem(key)) : null; } catch (e) { return null; } }
    if (!teamReq) {
      teamReq = navigator.onLine === false ? Promise.resolve(saved())
        : Promise.race([sb.rpc("my_team_info"), timeout(8000, { error: "timeout" })]).then(function (r) {
            if (r.error || !r.data) { teamReq = null; return saved(); }
            try { if (key) localStorage.setItem(key, JSON.stringify(r.data)); } catch (e) {}
            return r.data;
          }, function () { teamReq = null; return saved(); });
    }
    return teamReq;
  }
  // Forget the cached answer, after joining or leaving a team
  function teamChanged() { teamReq = null; }

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

  window.RS = { sb: sb, recovery: recovery, signOut: signOut, accessLevel: accessLevel, session: session,
                team: team, teamChanged: teamChanged, claimTeam: sendClaim, claimResultText: claimResultText };

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
    // 1307scout pages left out of the menu still highlight it
    var scoutToggle = document.getElementById("navScout");
    if (scoutToggle && /\/ratings(\.html)?$/.test(here)) scoutToggle.classList.add("active");
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

  // ── Which team are you on? (claim_team(), SQL section 3b) ──
  // Every account says which FRC team it's on, or that it isn't on one. The sign-up form asks
  // (saved as user_metadata.team_claim and sent here on the first page load); anyone else is
  // asked here, on every page until they answer. A claim the team's domain or an invitation
  // doesn't verify waits for the team's managers or site staff. The info site never asks.
  function escHtml(t) {
    return String(t == null ? "" : t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }
  async function sendClaim(team) {
    var r = await sb.rpc("claim_team", { p_team: team });
    if (r.error) throw r.error;
    teamChanged();
    return r.data || {};
  }
  function claimResultText(d) {
    if (d.status === "verified") return "You're on team " + d.team_number + ". Welcome!";
    if (d.status === "none") return "Got it: you're not on an FRC team. You can use 1307scout as a guest, and join a team later on Team Management.";
    return "Thanks. You'll be on team " + d.team_number + " once " +
      (d.team_known ? "one of its managers or site staff verify" : "site staff verify (team " + d.team_number + " isn't on 1307scout yet)") +
      " you. Until then you can use 1307scout as a guest. Team Management shows where it stands.";
  }
  // Asks for the account's name, its team, or both (askName / askTeam)
  function showTeamPrompt(info, askName, askTeam) {
    if (document.getElementById("rsTeamPrompt")) return;
    var box = document.createElement("div");
    box.id = "rsTeamPrompt";
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-modal", "true");
    box.setAttribute("aria-labelledby", "rsTpTitle");
    box.style.cssText = "position:fixed;inset:0;z-index:3000;background:rgba(10,20,40,.55);display:flex;align-items:center;justify-content:center;padding:16px;";
    var invites = !askTeam ? "" : (info.invites || []).map(function (iv) {
      return '<div style="border:1px solid var(--line);padding:.5rem .6rem;margin-bottom:.5rem;">' + escHtml(iv.name) + " (" + escHtml(iv.team_number) +
        ") invited you as a " + escHtml(iv.role) + '. <button type="button" class="btn btn-primary btn-sm" data-rs-accept="' + escHtml(iv.id) + '">Accept</button></div>';
    }).join("");
    box.innerHTML =
      '<form style="background:var(--white);color:var(--ink);max-width:440px;width:100%;padding:1.2rem 1.3rem;border:1px solid var(--line);box-shadow:0 10px 40px rgba(0,0,0,.3);" autocomplete="off">' +
        '<h2 id="rsTpTitle" style="font-size:1.2rem;margin:0 0 .4rem;">' + (askTeam ? "Which FRC team are you on?" : "What's your name?") + "</h2>" +
        (askName ? '<label for="rsTpName" style="display:block;font-size:.8rem;font-weight:600;color:var(--muted);margin:0 0 .15rem;">Your name</label>' +
          '<input type="text" id="rsTpName" class="form-control form-control-sm" maxlength="60" autocomplete="name" style="margin-bottom:.8rem;">' +
          (askTeam ? "" : '<p style="font-size:.88rem;color:var(--muted);margin:0 0 .8rem;">So your team knows who entered what. You can change it on My Account.</p>') : "") +
        (!askTeam ? "" :
        '<p style="font-size:.88rem;color:var(--muted);margin:0 0 .8rem;">1307scout is shared by FRC teams. Your team\'s own pages (strategy, pick list, pit crew) open once you\'re verified as a member: right away from your school email when your team set that up, otherwise by one of its managers.</p>' +
        invites +
        '<label style="display:flex;gap:.5rem;align-items:center;font-weight:400;margin:0 0 .4rem;"><input type="radio" name="rsTp" value="team" checked> I\'m on team ' +
          '<input type="number" id="rsTpTeam" class="form-control form-control-sm" min="1" max="99999" style="width:7rem;" aria-label="Team number"></label>' +
        '<label style="display:flex;gap:.5rem;align-items:center;font-weight:400;margin:0 0 .8rem;"><input type="radio" name="rsTp" value="none"> I\'m not on an FRC team</label>') +
        '<div id="rsTpMsg" role="status" style="font-size:.86rem;min-height:1.2em;margin-bottom:.5rem;color:var(--red);"></div>' +
        '<button type="submit" class="btn btn-primary btn-sm" id="rsTpGo">Continue</button> ' +
        '<button type="button" class="btn btn-link btn-sm" id="rsTpLater">Ask me later</button>' +
      "</form>";
    document.body.appendChild(box);
    var form = box.querySelector("form"), msg = box.querySelector("#rsTpMsg"), num = box.querySelector("#rsTpTeam"),
        nameBox = box.querySelector("#rsTpName");
    if (num) num.addEventListener("focus", function () { form.rsTp.value = "team"; });
    setTimeout(function () { (nameBox || num).focus(); }, 50);
    function done(text) {
      msg.style.color = "var(--green)";
      msg.textContent = text;
      box.querySelector("#rsTpGo").textContent = "OK";
      box.querySelector("#rsTpLater").hidden = true;
      form.onsubmit = function (e) { e.preventDefault(); location.reload(); };
    }
    box.querySelector("#rsTpLater").addEventListener("click", function () { box.remove(); });
    box.addEventListener("click", async function (e) {
      var b = e.target.closest("[data-rs-accept]");
      if (!b) return;
      var r = await sb.rpc("accept_team_invite", { p_id: Number(b.dataset.rsAccept) });
      if (r.error) { msg.textContent = r.error.message; return; }
      teamChanged();
      done("You're on team " + r.data + ". Welcome!");
    });
    form.onsubmit = async function (e) {
      e.preventDefault();
      var team = null, name = nameBox ? nameBox.value.trim() : "";
      if (nameBox && !name) { msg.textContent = "Enter your name."; return; }
      if (askTeam && form.rsTp.value === "team") {
        team = Number(num.value);
        if (!(Number.isInteger(team) && team >= 1 && team <= 99999)) { msg.textContent = "Enter your team number."; return; }
      }
      try {
        if (name) {
          var u = await sb.auth.updateUser({ data: { display_name: name.slice(0, 60) } });
          if (u.error) throw u.error;
        }
        done(askTeam ? claimResultText(await sendClaim(team)) : "Thanks, " + name.split(" ")[0] + ".");
      } catch (err) { msg.textContent = err.message || "Couldn't save that. Try again."; }
    };
  }
  // Staff acting as a team see it on every page, with a way back
  function showActingBar(info) {
    var bar = document.createElement("div");
    bar.setAttribute("role", "note");
    bar.style.cssText = "position:fixed;left:0;right:0;top:0;z-index:2100;padding:.15rem .75rem;font-size:.75rem;text-align:center;background:#6D28D9;color:#fff;";
    bar.innerHTML = "Staff view: acting as a manager of team " + escHtml(info.team_number) + ". " +
      '<a href="#" style="color:#fff;text-decoration:underline;" id="rsStopActing">Stop</a> · ' +
      '<a href="/team.html" style="color:#fff;text-decoration:underline;">Team Management</a>';
    document.body.appendChild(bar);
    bar.querySelector("#rsStopActing").addEventListener("click", async function (e) {
      e.preventDefault();
      await sb.rpc("staff_act_as_team", { p_team: null });
      teamChanged();
      try { localStorage.removeItem("rs_team_" + storedSession().user.id); } catch (x) {}
      location.reload();
    });
  }
  async function checkTeam(s) {
    if ((BUILD && BUILD.site === "info") || /\/signin(\.html)?$/.test(location.pathname) || navigator.onLine === false) return;
    var info = await team();
    if (!info) return;
    if (info.staff_acting) showActingBar(info);
    // Every account has a name: a Google sign-in's name is copied in, anyone else is asked
    var meta = s.user.user_metadata || {}, askName = !String(meta.display_name || "").trim();
    if (askName) {
      var google = String(meta.full_name || meta.name || "").trim();
      if (google) {
        askName = false;
        try { await sb.auth.updateUser({ data: { display_name: google.slice(0, 60) } }); } catch (e) { /* tried again next page */ }
      }
    }
    // Team Management asks for the team in the page itself
    var askTeam = !!info.needs_prompt && !/\/team(\.html)?$/.test(location.pathname);
    // An answer given on the sign-up form is sent once, without asking again
    var given = meta.team_claim;
    if (askTeam && given != null && given !== "") {
      try {
        await sendClaim(given === "none" ? null : Number(given));
        await sb.auth.updateUser({ data: { team_claim: null } });
        if (!askName) { location.reload(); return; }
        askTeam = false;
      } catch (e) { /* ask instead */ }
    }
    if (askName || askTeam) showTeamPrompt(info, askName, askTeam);
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
      if (!res.error) checkTeam(s);
    });
  });
})();