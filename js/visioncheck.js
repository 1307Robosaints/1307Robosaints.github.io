// How well the vision worker's numbers agree with human scouts, field by field, and whether a
// field agrees often enough for the Scout page to pre-fill it from vision (Match Flags shows the
// same numbers). Only confident vision rows count, and entries that were pre-filled from vision
// are left out, since they'd agree by construction. Explained on ratings.html#vision-prefill.
// Needs js/ratings.js and js/vision.js.
(function () {
  var MIN_PAIRS = 15;        // robot-matches with both a scout and vision before judging a field
  var READY_SHARE = 0.9;     // a yes/no field must agree this often to be pre-filled
  var FUEL_READY_SHARE = 0.8;
  function fuelTolerance(v) { return Math.max(10, 0.25 * v); }

  // Each check: the scouted value, the vision value, and whether they agree.
  // prefill names the Scout form field vision may fill in; FUEL is only a hint, since vision
  // counts the whole match and the form splits AUTO from teleop.
  var CHECKS = [
    { key: "auto_mobility", label: "Left starting zone (auto)", kind: "bool", prefill: "auto_mobility",
      scouted: function (d) { return typeof d.auto_mobility === "boolean" ? d.auto_mobility : null; },
      vision: function (v) { return typeof v.auto_left_zone === "boolean" ? v.auto_left_zone : null; },
      agree: function (a, b) { return a === b; } },
    { key: "fuel", label: "FUEL scored (whole match)", kind: "count", prefill: null,
      scouted: function (d) {
        var a = RSRatings.num(d.auto_fuel_hub), t = RSRatings.num(d.teleop_fuel_hub);
        return a == null && t == null ? null : (a || 0) + (t || 0);
      },
      vision: function (v) { return RSRatings.num(v.fuel_est); },
      agree: function (a, b) { return Math.abs(a - b) <= fuelTolerance(Math.max(a, b)); } }
  ];

  // entries: scouting_entries rows (team_number, match_number, data, prefilled) for one event.
  // vision: vision_robots rows (match_key, team_number, data, confidence) for the same event.
  function compare(entries, vision) {
    var byRobot = {};
    vision.forEach(function (v) {
      if (Number(v.confidence) >= RSVision.LOW_CONFIDENCE && v.data) byRobot[v.match_key + "|" + v.team_number] = v.data;
    });
    return CHECKS.map(function (c) {
      var pairs = 0, agree = 0, absDiff = 0;
      entries.forEach(function (e) {
        if (e.match_number == null || !e.data) return;
        if (c.prefill && (e.prefilled || []).indexOf(c.prefill) !== -1) return;
        var v = byRobot["qm" + e.match_number + "|" + e.team_number];
        if (!v) return;
        var a = c.scouted(e.data), b = c.vision(v);
        if (a == null || b == null) return;
        pairs++;
        if (c.agree(a, b)) agree++;
        if (c.kind === "count") absDiff += Math.abs(a - b);
      });
      var share = pairs ? agree / pairs : null;
      var needed = c.kind === "count" ? FUEL_READY_SHARE : READY_SHARE;
      return {
        key: c.key, label: c.label, kind: c.kind, prefill: c.prefill, pairs: pairs, agree: agree, share: share,
        meanDiff: c.kind === "count" && pairs ? absDiff / pairs : null,
        ready: pairs >= MIN_PAIRS && share >= needed, needed: needed
      };
    });
  }

  window.RSVisionCheck = {
    MIN_PAIRS: MIN_PAIRS, READY_SHARE: READY_SHARE, FUEL_READY_SHARE: FUEL_READY_SHARE,
    fuelTolerance: fuelTolerance, CHECKS: CHECKS, compare: compare
  };
})();
