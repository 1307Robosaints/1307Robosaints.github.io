// Component OPR: an estimate of how much of each official score field one team adds to its
// alliance, worked out from every qualification match at an event. Explained for users on
// ratings.html, which must change with this file.
//
// Each alliance's number is treated as the sum of its three robots' numbers, and the set of
// numbers that best fits every match (least squares) is the estimate. Early in an event there
// are too few matches for a unique answer, so a small pull toward the event average (RIDGE)
// keeps the estimates steady. Field names are never hard-coded: every numeric field in the
// score breakdown gets its own estimate, because the keys change every game.
(function () {
  var RIDGE = 1;            // pull toward the average, in "matches' worth" of evidence
  var MIN_TEAM_MATCHES = 3; // fewer than this and a team gets no estimate

  // Every numeric, alliance-level value in a breakdown, keyed by path ("a.b" when nested).
  // Per-robot fields (fooRobot1..3) aren't alliance totals, so they're skipped.
  function numericFields(obj, prefix, out) {
    out = out || {};
    if (!obj || typeof obj !== "object") return out;
    Object.keys(obj).forEach(function (k) {
      var v = obj[k], path = prefix ? prefix + "." + k : k;
      if (/Robot[1-3]$/i.test(k) || Array.isArray(v) || v == null) return;
      if (typeof v === "object") numericFields(v, path, out);
      else if (typeof v === "number" && isFinite(v)) out[path] = v;
    });
    return out;
  }

  // Solves (A + RIDGE*I) x = b for symmetric positive definite A, by Cholesky.
  function cholesky(a) {
    var n = a.length, L = [];
    for (var i = 0; i < n; i++) {
      L.push(new Array(n).fill(0));
      for (var j = 0; j <= i; j++) {
        var sum = a[i][j];
        for (var k = 0; k < j; k++) sum -= L[i][k] * L[j][k];
        L[i][j] = i === j ? Math.sqrt(Math.max(sum, 1e-12)) : sum / L[j][j];
      }
    }
    return L;
  }
  function solve(L, b) {
    var n = L.length, y = new Array(n), x = new Array(n), i, k, sum;
    for (i = 0; i < n; i++) {
      for (sum = b[i], k = 0; k < i; k++) sum -= L[i][k] * y[k];
      y[i] = sum / L[i][i];
    }
    for (i = n - 1; i >= 0; i--) {
      for (sum = y[i], k = i + 1; k < n; k++) sum -= L[k][i] * x[k];
      x[i] = sum / L[i][i];
    }
    return x;
  }

  // matches: played qualification rows from official_matches_combined for ONE event.
  // Returns { teams: {team: {matches, score, fields: {path: value}}}, fields: [paths], matches }.
  function compute(matches) {
    var rows = [];   // one per alliance appearance
    matches.forEach(function (m) {
      if (m.comp_level && m.comp_level !== "qm") return;
      if (m.red_score == null || m.blue_score == null) return;
      [["red", m.red_teams, m.red_score, m.red_breakdown], ["blue", m.blue_teams, m.blue_score, m.blue_breakdown]]
        .forEach(function (side) {
          var teams = (side[1] || []).filter(function (t) { return t != null; });
          if (!teams.length) return;
          var vals = numericFields(side[3], "");
          vals.__score = side[2];
          rows.push({ teams: teams, vals: vals });
        });
    });
    var teamList = [], index = {}, counts = {};
    rows.forEach(function (r) {
      r.teams.forEach(function (t) {
        if (!(t in index)) { index[t] = teamList.length; teamList.push(t); }
        counts[t] = (counts[t] || 0) + 1;
      });
    });
    var n = teamList.length, out = { teams: {}, fields: [], matches: rows.length / 2 };
    if (!n) return out;

    // A field counts if most alliances report it
    var seen = {};
    rows.forEach(function (r) { Object.keys(r.vals).forEach(function (k) { seen[k] = (seen[k] || 0) + 1; }); });
    var fields = Object.keys(seen).filter(function (k) { return seen[k] >= rows.length / 2; });

    // Normal equations: AtA is shared by every field, so it's factored once
    var ata = [];
    for (var i = 0; i < n; i++) ata.push(new Array(n).fill(0));
    rows.forEach(function (r) {
      r.teams.forEach(function (a) {
        r.teams.forEach(function (b) { ata[index[a]][index[b]] += 1; });
      });
    });
    for (i = 0; i < n; i++) ata[i][i] += RIDGE;
    var L = cholesky(ata);

    teamList.forEach(function (t) { out.teams[t] = { matches: counts[t], fields: {} }; });
    fields.forEach(function (f) {
      // Fit what's left after the average robot's share, so the ridge pulls toward that average
      var have = rows.filter(function (r) { return typeof r.vals[f] === "number"; });
      var perRobot = have.reduce(function (s, r) { return s + r.vals[f] / r.teams.length; }, 0) / have.length;
      var atb = new Array(n).fill(0);
      have.forEach(function (r) {
        var resid = r.vals[f] - perRobot * r.teams.length;
        r.teams.forEach(function (t) { atb[index[t]] += resid; });
      });
      var x = solve(L, atb);
      teamList.forEach(function (t, j) {
        if (counts[t] < MIN_TEAM_MATCHES) return;
        var v = perRobot + x[j];
        if (f === "__score") out.teams[t].score = v;
        else out.teams[t].fields[f] = v;
      });
    });
    out.fields = fields.filter(function (f) { return f !== "__score"; }).sort();
    return out;
  }

  // Where a team's value ranks among teams at the event, 1 = highest
  function rankOf(result, team, field) {
    var get = function (t) { return field ? result.teams[t].fields[field] : result.teams[t].score; };
    var mine = result.teams[team] ? get(team) : null;
    if (mine == null) return null;
    var all = Object.keys(result.teams).map(get).filter(function (v) { return v != null; });
    return { rank: all.filter(function (v) { return v > mine + 1e-9; }).length + 1, of: all.length };
  }

  window.RSOpr = { compute: compute, rankOf: rankOf, numericFields: numericFields, MIN_TEAM_MATCHES: MIN_TEAM_MATCHES };
})();
