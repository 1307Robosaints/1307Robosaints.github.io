// Labels for the per-robot numbers the vision worker (vision/ folder) saves in
// vision_robots.data. Keep in step with metrics.py there and with ratings.html.
(function () {
  // [key, label, kind]: kind is "share" (0-1, shown as %), "bool", "sec", "ft" or "count"
  var FIELDS = [
    ["fuel_est",         "Estimated FUEL scored",               "count"],
    ["fuel_share",       "Share of alliance FUEL credited",     "share"],
    ["auto_left_zone",   "Left starting zone (auto)",           "bool"],
    ["auto_distance_ft", "Distance driven in auto (ft)",        "ft"],
    ["distance_ft",      "Distance driven (ft)",                "ft"],
    ["own_zone_s",       "Time in own alliance zone (s)",       "sec"],
    ["neutral_zone_s",   "Time in neutral zone (s)",            "sec"],
    ["opp_zone_s",       "Time in opponent's zone (s)",         "sec"],
    ["longest_still_s",  "Longest stop before endgame (s)",     "sec"],
    ["still_s",          "Total time stopped before endgame (s)", "sec"],
    ["contacts",         "Close contacts with opponents",       "count"],
    ["visible_share",    "Share of match tracked",              "share"],
    ["id_share",         "Share identified by bumper number",   "share"],
    ["look_share",       "Share identified by look",            "share"]
  ];
  function fmt(kind, v) {
    if (v == null || v === "") return "—";
    if (kind === "bool") return v ? "Yes" : "No";
    if (kind === "share") return Math.round(Number(v) * 100) + "%";
    return Number(v).toFixed(kind === "count" ? 1 : 0);
  }
  window.RSVision = { FIELDS: FIELDS, fmt: fmt, LOW_CONFIDENCE: 0.5 };
})();
