// Sortable, searchable tables, shared by every page that loads this file.
//
//   <table data-sortable="key">   Click a header to sort by it; again to reverse. The arrows show
//                                  which column and which way. key keeps the choice when the page
//                                  redraws the table (polling, filters), so give each table its own.
//   <th data-nosort>               A column that can't be sorted (headers with no text never are).
//   <td data-sort="value">         What to sort by, when the text isn't it (an ISO date, a number).
//   <tr data-search="text">        Extra text the search box matches (an email shown elsewhere).
//   <input data-table-search="key1 key2">  Filters the rows of those tables as you type. Every
//                                  word must match somewhere in the row: a name, email or number.
//   RSTables.setFilter(key, fn)    An extra filter, fn(tr) -> show it? (null removes it), e.g. by event.
//
// Numbers sort by size, other text alphabetically with numbers in it in order ("Qual 2" before
// "Qual 10"). Blanks and dashes always go last. Rows that span the whole table (an "empty" note)
// stay put. A table drawn later is set up automatically, so pages need no extra calls.
window.RSTables = (function () {
  var sorts = {};     // key -> { col, dir: 1 | -1 }
  var filters = {};   // key -> fn(tr)
  var searches = {};  // key -> words from the search box
  var skip = new WeakSet();   // tbodies this module just reordered (its own mutations)
  var collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

  function keyOf(t) { return t.getAttribute("data-sortable") || ""; }
  function heads(t) {
    var rows = t.tHead ? t.tHead.rows : [];
    return rows.length ? Array.prototype.slice.call(rows[rows.length - 1].cells) : [];
  }
  // A cell's text, reading a select by its chosen option rather than every option
  function cellText(td) {
    if (!td) return "";
    var sel = td.querySelector("select");
    if (sel) return sel.selectedIndex >= 0 ? sel.options[sel.selectedIndex].text : "";
    var inp = td.querySelector("input:not([type=checkbox]):not([type=radio])");
    if (inp) return inp.value;
    return td.textContent.trim();
  }
  function cellValue(td) {
    if (!td) return null;
    var v = td.hasAttribute("data-sort") ? td.getAttribute("data-sort") : cellText(td);
    v = String(v).trim();
    return v === "" || v === "—" || v === "-" ? null : v;
  }
  function compare(a, b) {
    var na = Number(a.replace(/,/g, "")), nb = Number(b.replace(/,/g, ""));
    if (!isNaN(na) && !isNaN(nb)) return na - nb;
    return collator.compare(a, b);
  }
  function bodyRows(t) {
    var out = [];
    Array.prototype.forEach.call(t.tBodies, function (b) {
      Array.prototype.forEach.call(b.rows, function (r) { out.push(r); });
    });
    return out;
  }
  function spansAll(tr) { return tr.cells.length === 1 && tr.cells[0].colSpan > 1; }

  function rowText(tr) {
    return (Array.prototype.map.call(tr.cells, cellText).join(" ") + " " + (tr.getAttribute("data-search") || "")).toLowerCase();
  }
  // Shows the rows the search box and any filter allow
  function applyFilter(t) {
    var key = keyOf(t), words = searches[key] || [], fn = filters[key];
    bodyRows(t).forEach(function (tr) {
      if (spansAll(tr)) return;
      var text = words.length ? rowText(tr) : "";
      tr.hidden = !(words.every(function (w) { return text.indexOf(w) !== -1; }) && (!fn || fn(tr)));
    });
  }
  function applySort(t) {
    var s = sorts[keyOf(t)];
    heads(t).forEach(function (th, i) {
      if (!th.classList.contains("rs-sortable")) return;
      var on = !!s && s.col === i;
      th.classList.toggle("rs-asc", on && s.dir === 1);
      th.classList.toggle("rs-desc", on && s.dir === -1);
      th.setAttribute("aria-sort", on ? (s.dir === 1 ? "ascending" : "descending") : "none");
    });
    if (!s) return;
    Array.prototype.forEach.call(t.tBodies, function (body) {
      var rows = Array.prototype.slice.call(body.rows);
      if (rows.some(spansAll)) return;
      var keyed = rows.map(function (r, i) { return { r: r, v: cellValue(r.cells[s.col]), i: i }; });
      keyed.sort(function (a, b) {
        if (a.v === null || b.v === null) return a.v === b.v ? a.i - b.i : a.v === null ? 1 : -1;   // blanks last
        return s.dir * compare(a.v, b.v) || a.i - b.i;
      });
      if (keyed.every(function (k, i) { return k.r === rows[i]; })) return;
      skip.add(body);
      keyed.forEach(function (k) { body.appendChild(k.r); });
    });
  }
  function apply(t) { applySort(t); applyFilter(t); }

  // Adds the arrows and click handling to a table's headers, once
  function setUp(t) {
    if (t.getAttribute("data-rs-ready") === "1") return;
    t.setAttribute("data-rs-ready", "1");
    // Merged header or body cells would put the columns out of line: leave such a table alone
    if (heads(t).some(function (th) { return th.colSpan > 1; }) || t.querySelector("tbody td[rowspan]")) return;
    heads(t).forEach(function (th, i) {
      if (th.hasAttribute("data-nosort") || !th.textContent.trim() || th.colSpan > 1) return;
      th.classList.add("rs-sortable");
      th.tabIndex = 0;
      th.title = th.title || "Sort by " + th.textContent.trim();
      var arrows = document.createElement("span");
      arrows.className = "rs-arrows";
      arrows.setAttribute("aria-hidden", "true");
      arrows.innerHTML = '<span class="rs-up">&#9650;</span><span class="rs-down">&#9660;</span>';
      th.appendChild(arrows);
      function go() {
        var key = keyOf(t), s = sorts[key];
        sorts[key] = { col: i, dir: s && s.col === i ? -s.dir : 1 };
        apply(t);
      }
      th.addEventListener("click", function (e) { if (!e.target.closest("button,a,input,select")) go(); });
      th.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); go(); } });
    });
    apply(t);
  }
  function scan(root) {
    (root || document).querySelectorAll("table[data-sortable]").forEach(function (t) {
      if (t.getAttribute("data-rs-ready") === "1") apply(t); else setUp(t);
    });
  }

  // Tables drawn or redrawn later: set them up, or re-sort and re-filter their new rows
  var pending = new Set(), queued = false;
  new MutationObserver(function (list) {
    list.forEach(function (m) {
      var body = m.target.closest ? m.target.closest("tbody") : null;
      if (body && skip.has(body)) return;
      var t = m.target.closest ? m.target.closest("table[data-sortable]") : null;
      if (t) pending.add(t);
      else if (m.addedNodes.length) pending.add(null);   // look for new tables
    });
    list.forEach(function (m) {
      var body = m.target.closest ? m.target.closest("tbody") : null;
      if (body) skip.delete(body);
    });
    if (queued || !pending.size) return;
    queued = true;
    requestAnimationFrame(function () {
      queued = false;
      var all = pending.has(null);
      pending.forEach(function (t) { if (t && document.contains(t)) (t.getAttribute("data-rs-ready") === "1" ? apply : setUp)(t); });
      pending.clear();
      if (all) scan();
    });
  }).observe(document.documentElement, { childList: true, subtree: true });

  // Search boxes, wired by attribute
  document.addEventListener("input", function (e) {
    var box = e.target.closest && e.target.closest("[data-table-search]");
    if (!box) return;
    var words = box.value.toLowerCase().split(/\s+/).filter(Boolean);
    box.getAttribute("data-table-search").split(/\s+/).forEach(function (key) {
      searches[key] = words;
      document.querySelectorAll('table[data-sortable="' + key + '"]').forEach(applyFilter);
    });
  });
  document.addEventListener("DOMContentLoaded", function () { scan(); });

  return {
    setFilter: function (key, fn) {
      if (fn) filters[key] = fn; else delete filters[key];
      document.querySelectorAll('table[data-sortable="' + key + '"]').forEach(applyFilter);
    },
    refresh: scan
  };
})();
