// The red and blue picks for the Alliance View, shared by query.html (add buttons) and
// alliance.html (the comparison). Only team numbers are kept, in this browser's localStorage.
(function () {
  var KEY = "rs_alliances";
  var MAX = 3;

  function clean(list) {
    if (!Array.isArray(list)) return [];
    return list.filter(function (t) { return Number.isInteger(t) && t > 0; }).slice(0, MAX);
  }
  function read() {
    try {
      var saved = JSON.parse(localStorage.getItem(KEY)) || {};
      return { red: clean(saved.red), blue: clean(saved.blue) };
    } catch (e) {
      return { red: [], blue: [] };
    }
  }
  function write(state) {
    try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {}
  }

  window.Alliance = {
    MAX: MAX,
    get: read,
    colorOf: function (team) {
      var s = read();
      return s.red.indexOf(team) !== -1 ? "red" : s.blue.indexOf(team) !== -1 ? "blue" : null;
    },
    // A team can only be on one alliance, so adding it to the other side moves it.
    // Returns false if that alliance is already full.
    add: function (color, team) {
      var s = read();
      if (s[color].indexOf(team) !== -1) return true;
      if (s[color].length >= MAX) return false;
      var other = color === "red" ? "blue" : "red";
      s[other] = s[other].filter(function (t) { return t !== team; });
      s[color].push(team);
      write(s);
      return true;
    },
    remove: function (team) {
      var s = read();
      var keep = function (t) { return t !== team; };
      write({ red: s.red.filter(keep), blue: s.blue.filter(keep) });
    },
    clear: function () { write({ red: [], blue: [] }); }
  };
})();
