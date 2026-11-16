// Offline copies. Some pages can save what they show as one standalone .html file that opens with
// no connection: the Team Database's team view, the Alliance View, and a simplified Playoff
// Selection board. A copy is a snapshot. It never updates, and it says when it was saved.
//
//   RSOffline.snapshot(el, opts)  saves a rendered part of the page: the styles it uses are copied
//                                 in, photos and logos are embedded (shrunk), and buttons and other
//                                 controls are left out.
//   RSOffline.board(data, opts)   saves the playoff pick board, a small app that works offline.
(function () {
  var SITE = /^https:/.test(location.origin) ? location.origin : "https://scout.robosaints1307.com";
  var IMG_MAX = 640;   // longest side of an embedded photo, in pixels

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  function stamp() {
    return new Date().toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  }
  // "Team 1678 Citrus" -> "team-1678-citrus", for file names
  function slug(s) {
    return String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60) || "copy";
  }
  function fileName(name) {
    return "1307scout-" + slug(name) + "-" + new Date().toISOString().slice(0, 10) + ".html";
  }

  // Hands the file to the browser as a download
  function save(name, html) {
    var url = URL.createObjectURL(new Blob([html], { type: "text/html;charset=utf-8" }));
    var a = document.createElement("a");
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
  }

  // A whole document: the page's own styles, a bar saying what this is, then the content
  function page(title, css, body, bodyAttrs, script) {
    return "<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">" +
      '<meta name="viewport" content="width=device-width, initial-scale=1">' +
      "<title>" + esc(title) + "</title><style>" + css + OFFLINE_CSS + "</style></head>" +
      "<body" + (bodyAttrs || "") + ">" +
      '<div class="rs-offline-bar"><strong>' + esc(title) + "</strong> · Offline copy saved " + esc(stamp()) +
      " from 1307scout. It doesn't update: download it again for the latest data.</div>" +
      body + (script ? "<script>" + script + "</script>" : "") + "</body></html>";
  }
  var OFFLINE_CSS =
    ".rs-offline-bar{font:14px/1.4 system-ui,sans-serif;background:#fff6d6;color:#3d3200;border-bottom:1px solid #e3cf7a;padding:.55rem 1rem;margin:0 0 1rem}" +
    // relative, not static: some pages pin a box to the corner of the copied panel
    ".rs-offline-root{max-height:none!important;height:auto!important;overflow:visible!important;position:relative!important;top:auto!important;margin:0 auto;padding:0 1rem 2rem}" +
    ".rs-offline-wrap{display:block!important;max-width:none!important;height:auto!important;overflow:visible!important;position:static!important;margin:0!important;padding:0!important}" +
    "@media print{.rs-offline-bar{border:1px solid #999}}";

  // ── Styles: only the rules that match something in the copy ─────────
  function cssFor(doc) {
    var out = [];
    function used(selector) {
      // :hover, ::before and the like can't be matched against a static copy, so drop them first
      var plain = selector.replace(/::?[a-zA-Z-]+(\([^)]*\))?/g, "").trim();
      if (!plain) return true;
      try { return !!doc.querySelector(plain); } catch (e) { return true; }
    }
    function walk(rules) {
      var kept = [];
      Array.prototype.forEach.call(rules, function (rule) {
        if (rule.type === 1) {   // style rule
          if (rule.selectorText.split(",").some(used)) kept.push(rule.cssText);
        } else if (rule.type === 4) {   // @media
          var inner = walk(rule.cssRules);
          if (inner.length) kept.push("@media " + rule.media.mediaText + "{" + inner.join("") + "}");
        } else if (rule.type !== 5 && rule.type !== 3) {   // not @font-face or @import: fonts don't come along
          kept.push(rule.cssText);
        }
      });
      return kept;
    }
    Array.prototype.forEach.call(document.styleSheets, function (sheet) {
      var rules;
      try { rules = sheet.cssRules; } catch (e) { return; }   // another site's sheet without CORS
      if (rules) out = out.concat(walk(rules));
    });
    return out.join("\n");
  }

  // ── Images: embedded, so they show offline ───────────────────────────
  function dataUrl(blob) {
    return new Promise(function (resolve, reject) {
      var r = new FileReader();
      r.onload = function () { resolve(r.result); };
      r.onerror = reject;
      r.readAsDataURL(blob);
    });
  }
  async function shrink(blob) {
    if (blob.size < 60000 || !window.createImageBitmap) return dataUrl(blob);
    try {
      var bmp = await createImageBitmap(blob);
      var scale = Math.min(1, IMG_MAX / Math.max(bmp.width, bmp.height));
      var c = document.createElement("canvas");
      c.width = Math.round(bmp.width * scale);
      c.height = Math.round(bmp.height * scale);
      c.getContext("2d").drawImage(bmp, 0, 0, c.width, c.height);
      return c.toDataURL(blob.type === "image/png" ? "image/png" : "image/jpeg", 0.82);
    } catch (e) {
      return dataUrl(blob);   // a format the browser can't draw (HEIC on most browsers)
    }
  }
  // An image that can't be fetched keeps its web address, so it still shows when online
  async function embedImages(root) {
    var cache = {};
    await Promise.all(Array.prototype.map.call(root.querySelectorAll("img[src]"), async function (img) {
      var src = img.getAttribute("src");
      if (/^data:/.test(src)) return;
      var abs = new URL(src, location.href).href;
      img.removeAttribute("loading");
      try {
        if (!cache[abs]) {
          cache[abs] = fetch(abs, { mode: "cors", credentials: "omit" }).then(function (r) {
            if (!r.ok) throw new Error(r.status);
            return r.blob();
          }).then(shrink);
        }
        img.setAttribute("src", await cache[abs]);
      } catch (e) {
        img.setAttribute("src", abs);
      }
    }));
  }

  // ── Snapshot of part of the page ───────────────────────────────────
  // opts: title, file (name for the file), remove (extra selectors to leave out)
  async function snapshot(el, opts) {
    var copy = el.cloneNode(true);   // ids stay, so styles like "#detail h2" still apply
    copy.classList.add("rs-offline-root");
    var drop = ["script", "button", "input", "select", "textarea", "i.fa", "[data-offline-skip]", ".sr-only"]
      .concat(opts.remove || []);
    copy.querySelectorAll(drop.join(",")).forEach(function (n) { n.remove(); });
    copy.querySelectorAll("details").forEach(function (d) { d.setAttribute("open", ""); });
    copy.querySelectorAll("[onclick]").forEach(function (n) { n.removeAttribute("onclick"); });
    copy.querySelectorAll("a[href]").forEach(function (a) {
      var href = a.getAttribute("href");
      if (/^#/.test(href)) { a.removeAttribute("href"); return; }
      a.setAttribute("href", new URL(href, SITE + location.pathname).href);
      a.setAttribute("target", "_blank");
      a.setAttribute("rel", "noopener noreferrer");
    });

    // Rebuild the element's parents (without their other contents), so styles written for
    // ".page .card" still apply. Layout on the parents is reset, since their siblings are gone.
    var doc = document.implementation.createHTMLDocument("");
    var inner = copy;
    for (var p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      var shell = p.cloneNode(false);
      shell.classList.add("rs-offline-wrap");
      shell.appendChild(inner);
      inner = shell;
    }
    doc.body.className = document.body.className;
    doc.body.appendChild(doc.importNode(inner, true));
    await embedImages(doc.body);

    var css = cssFor(doc);
    var attrs = document.body.className ? ' class="' + esc(document.body.className) + '"' : "";
    save(fileName(opts.file || opts.title), page(opts.title, css, doc.body.innerHTML, attrs));
  }

  // Runs a download from a button, showing that it's working and any failure
  async function fromButton(btn, work) {
    if (btn.disabled) return;
    var label = btn.innerHTML;
    btn.disabled = true;
    btn.textContent = "Preparing…";
    try {
      await work();
    } catch (e) {
      console.error("Offline copy failed:", e);
      var text = "Couldn't make the offline copy: " + (e && e.message ? e.message : e);
      if (window.RSDialog) RSDialog.alert(text, { title: "Download failed" }); else alert(text);
    } finally {
      btn.disabled = false;
      btn.innerHTML = label;
    }
  }

  // ── Offline playoff board ──────────────────────────────────────────
  // data: { event, slots, alliances, picks: [[alliance, slot, team]], columns: [{ key, label, group,
  //         title, lower, text, grade }], tiers: { S: { color, ink } }, teams: [{ team, name,
  //         season: [cell], event: [cell] }] } where a cell is [sortValue, shownText, gradeTier?]
  function board(data, opts) {
    var json = JSON.stringify(data).replace(/</g, "\\u003c");
    var body = '<main class="ob">' +
      '<div class="ob-head"><h1>' + esc(data.event) + ' · Playoff Selection</h1>' +
      '<p>Picks made here stay on this device and don\'t reach the team. <button type="button" id="obReset">Back to the downloaded picks</button></p></div>' +
      '<form id="obAdd" class="ob-add"><label for="obTeam">Next: <span id="obNext"></span></label>' +
      '<input id="obTeam" type="number" min="1" max="99999" inputmode="numeric" placeholder="Team #"><button type="submit">Add</button>' +
      '<span id="obMsg" role="status"></span></form>' +
      '<section id="obBoard" class="ob-board"></section>' +
      '<div class="ob-pool-head"><h2>Remaining teams <span id="obCount"></span></h2>' +
      '<div class="ob-scope"><button type="button" data-scope="season">All season</button><button type="button" data-scope="event">This event</button></div></div>' +
      '<div class="ob-scroll"><table id="obPool"></table></div></main>' +
      '<script type="application/json" id="rs-data">' + json + "</script>";
    save(fileName(opts.file), page(data.event + " playoff selection", BOARD_CSS, body, "", "(" + boardApp.toString() + ")();"));
  }
  var BOARD_CSS =
    "*{box-sizing:border-box}body{margin:0;font:14px/1.4 system-ui,-apple-system,Segoe UI,sans-serif;color:#1d2330;background:#f4f6f9}" +
    ".ob{padding:0 1rem 2rem;max-width:1600px;margin:0 auto}.ob h1{font-size:1.35rem;margin:0 0 .25rem}.ob h2{font-size:1.1rem;margin:0}" +
    ".ob-head p{margin:0 0 .75rem;color:#555}button{font:inherit;cursor:pointer;border:1px solid #9aa5b8;background:#fff;border-radius:6px;padding:.2rem .6rem}" +
    "button.on{background:#173f8f;color:#fff;border-color:#173f8f}" +
    ".ob-add{display:flex;flex-wrap:wrap;gap:.5rem;align-items:center;margin-bottom:.75rem}.ob-add input{width:7rem;padding:.3rem;border:1px solid #9aa5b8;border-radius:6px;font:inherit}" +
    "#obMsg{color:#a83228}.ob-board{display:grid;grid-template-columns:repeat(auto-fill,minmax(270px,1fr));gap:.6rem;margin-bottom:1.25rem}" +
    ".ob-al{background:#fff;border:1px solid #d5dbe5;border-radius:8px;padding:.5rem}.ob-al.active{border-color:#f5c400;box-shadow:0 0 0 2px #f5c400}" +
    ".ob-al h3{font-size:.95rem;margin:0 0 .35rem}.ob-slots{display:grid;grid-template-columns:repeat(var(--n),1fr);gap:.3rem}" +
    ".ob-slot{border:1px dashed #b7c0cf;border-radius:6px;padding:.3rem;min-height:3.2rem;text-align:left;background:#fafbfc;position:relative}" +
    ".ob-slot.filled{border-style:solid;background:#fff}.ob-slot.target{border-color:#e0a800;background:#fff8dc}" +
    ".ob-role{display:block;font-size:.7rem;color:#667}.ob-num{font-weight:700}.ob-name{display:block;font-size:.72rem;color:#555;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}" +
    ".ob-x{position:absolute;top:2px;right:2px;border:0;background:none;padding:0 .3rem;color:#a83228}" +
    ".ob-pool-head{display:flex;flex-wrap:wrap;gap:.5rem;justify-content:space-between;align-items:center;margin-bottom:.4rem}#obCount{font-weight:400;color:#666;font-size:.9rem}" +
    ".ob-scroll{overflow-x:auto;background:#fff;border:1px solid #d5dbe5;border-radius:8px}" +
    "table{border-collapse:collapse;width:100%;white-space:nowrap}th,td{padding:.3rem .5rem;border-bottom:1px solid #e6eaf0;text-align:right}" +
    "th{position:sticky;top:0;background:#eef1f6;font-size:.78rem}th.g{text-align:center;background:#e2e7f0}th button{border:0;background:none;padding:0;font-weight:700}" +
    "td.t,th.t{text-align:left}td.tm{text-align:left;position:sticky;left:0;background:#fff}td.tm small{display:block;color:#666;max-width:12rem;overflow:hidden;text-overflow:ellipsis}" +
    ".gr{display:inline-block;min-width:1.5rem;text-align:center;border-radius:4px;font-weight:700;margin-right:.3rem;padding:0 .2rem}";

  // The offline board itself. It runs inside the downloaded file, so it can't use anything else in
  // this script or the site: everything it needs is in the embedded data.
  function boardApp() {
    var D = JSON.parse(document.getElementById("rs-data").textContent);
    var NAMES = ["Captain", "1st pick", "2nd pick", "3rd pick"];
    var KEY = "rs-offline-board|" + D.event + "|" + D.saved;
    var $ = function (id) { return document.getElementById(id); };
    function esc(s) {
      return String(s == null ? "" : s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }
    var byTeam = {};
    D.teams.forEach(function (t) { byTeam[t.team] = t; });
    var picks, chosen = null, scope = "season", sortCol = 0, sortDir = -1;
    function load() {
      try { var s = JSON.parse(localStorage.getItem(KEY)); if (Array.isArray(s)) return s; } catch (e) {}
      return D.picks.slice();
    }
    function store() { try { localStorage.setItem(KEY, JSON.stringify(picks)); } catch (e) {} }
    function at(a, s) { return picks.find(function (p) { return p[0] === a && p[1] === s; }); }
    // Captains and first picks 1 to 8, second picks 8 to 1, then any third picks 1 to 8
    function order() {
      var o = [], a;
      for (a = 1; a <= D.alliances; a++) o.push([a, 1], [a, 2]);
      for (a = D.alliances; a >= 1; a--) o.push([a, 3]);
      if (D.slots === 4) for (a = 1; a <= D.alliances; a++) o.push([a, 4]);
      return o;
    }
    function target() {
      if (chosen && !at(chosen[0], chosen[1])) return chosen;
      chosen = null;
      return order().find(function (s) { return !at(s[0], s[1]); }) || null;
    }
    function say(t) { $("obMsg").textContent = t || ""; }
    function place(team) {
      var spot = target();
      if (!spot) return say("Every spot is filled.");
      var on = picks.find(function (p) { return p[2] === team; });
      if (on) return say("Team " + team + " is already on Alliance " + on[0] + ".");
      picks.push([spot[0], spot[1], team]);
      chosen = null;
      say("");
      store();
      render();
    }
    function renderBoard() {
      var tg = target(), html = "";
      for (var a = 1; a <= D.alliances; a++) {
        var cells = "";
        for (var s = 1; s <= D.slots; s++) {
          var p = at(a, s), isT = tg && tg[0] === a && tg[1] === s;
          var role = '<span class="ob-role">' + NAMES[s - 1] + "</span>";
          cells += p
            ? '<div class="ob-slot filled">' + role + '<span class="ob-num">' + p[2] + '</span><span class="ob-name">' +
              esc(byTeam[p[2]] ? byTeam[p[2]].name : "") + '</span><button type="button" class="ob-x" data-x="' + a + "," + s +
              '" aria-label="Remove team ' + p[2] + '">×</button></div>'
            : '<button type="button" class="ob-slot' + (isT ? " target" : "") + '" data-spot="' + a + "," + s + '">' + role +
              (isT ? "Next up" : "+") + "</button>";
        }
        html += '<div class="ob-al' + (tg && tg[0] === a ? " active" : "") + '"><h3>Alliance ' + a + '</h3><div class="ob-slots" style="--n:' +
          D.slots + '">' + cells + "</div></div>";
      }
      $("obBoard").innerHTML = html;
      $("obNext").textContent = tg ? "Alliance " + tg[0] + ", " + NAMES[tg[1] - 1] : "all spots filled";
    }
    function cmp(x, y) {
      if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
      return sortDir * (typeof x === "string" ? x.localeCompare(y) : x - y);
    }
    function cellHtml(c) {
      if (c[2]) {
        var g = D.tiers[c[2]] || { color: "#ddd", ink: "#222" };
        return '<span class="gr" style="background:' + g.color + ";color:" + g.ink + '">' + esc(c[2]) + "</span>" + esc(c[1]);
      }
      return esc(c[1]);
    }
    function renderPool() {
      var taken = new Set(picks.map(function (p) { return p[2]; }));
      var left = D.teams.filter(function (t) { return !taken.has(t.team); });
      left.sort(function (a, b) { return cmp(a[scope][sortCol][0], b[scope][sortCol][0]) || a.team - b.team; });
      var groups = "", i = 0;
      while (i < D.columns.length) {
        var n = D.columns.filter(function (c) { return c.group === D.columns[i].group; }).length;
        groups += '<th class="g" colspan="' + n + '">' + esc(D.columns[i].group) + "</th>";
        i += n;
      }
      var head = D.columns.map(function (c, k) {
        return '<th class="' + (c.text ? "t" : "") + '"><button type="button" data-sort="' + k + '"' + (c.title ? ' title="' + esc(c.title) + '"' : "") + ">" +
          esc(c.label) + (k === sortCol ? (sortDir > 0 ? " ▲" : " ▼") : "") + "</button></th>";
      }).join("");
      var rows = left.map(function (t, r) {
        return '<tr><td>' + (r + 1) + '</td><td class="tm"><button type="button" data-pick="' + t.team + '">Pick</button> <strong>' + t.team +
          "</strong><small>" + esc(t.name) + "</small></td>" +
          t[scope].map(function (c, k) { return '<td class="' + (D.columns[k].text ? "t" : "") + '">' + cellHtml(c) + "</td>"; }).join("") + "</tr>";
      }).join("");
      $("obPool").innerHTML = '<thead><tr><th></th><th></th>' + groups + '</tr><tr><th>#</th><th class="t">Team</th>' + head + "</tr></thead><tbody>" +
        (rows || '<tr><td colspan="' + (D.columns.length + 2) + '" class="t">Every team is on an alliance.</td></tr>') + "</tbody>";
      $("obCount").textContent = left.length + " of " + D.teams.length + " available";
      document.querySelectorAll("[data-scope]").forEach(function (b) { b.classList.toggle("on", b.dataset.scope === scope); });
    }
    function render() { renderBoard(); renderPool(); }

    $("obBoard").addEventListener("click", function (e) {
      var x = e.target.closest("[data-x]");
      if (x) {
        var k = x.dataset.x.split(",").map(Number);
        picks = picks.filter(function (p) { return !(p[0] === k[0] && p[1] === k[1]); });
        store();
        return render();
      }
      var s = e.target.closest("[data-spot]");
      if (s) { chosen = s.dataset.spot.split(",").map(Number); renderBoard(); $("obTeam").focus(); }
    });
    $("obPool").addEventListener("click", function (e) {
      var p = e.target.closest("[data-pick]");
      if (p) return place(Number(p.dataset.pick));
      var h = e.target.closest("[data-sort]");
      if (!h) return;
      var k = Number(h.dataset.sort), c = D.columns[k];
      if (k === sortCol) sortDir = -sortDir;
      else { sortCol = k; sortDir = c.lower || c.text ? 1 : -1; }
      renderPool();
    });
    $("obAdd").addEventListener("submit", function (e) {
      e.preventDefault();
      var t = Number($("obTeam").value);
      if (!Number.isInteger(t) || t < 1 || t > 99999) return say("Enter a team number.");
      place(t);
      $("obTeam").value = "";
    });
    document.querySelector(".ob-scope").addEventListener("click", function (e) {
      var b = e.target.closest("[data-scope]");
      if (b) { scope = b.dataset.scope; renderPool(); }
    });
    $("obReset").addEventListener("click", function () {
      if (!confirm("Undo every change made in this copy and go back to the downloaded picks?")) return;
      picks = D.picks.slice();
      chosen = null;
      store();
      render();
    });
    picks = load();
    render();
  }

  window.RSOffline = { snapshot: snapshot, board: board, fromButton: fromButton };
})();
