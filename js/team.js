// Team settings shared by Team Management (team.html) and the pages they configure. A team's
// own choices come from RS.team() (my_team_info() in SQL section 3b); these are the defaults
// for anything it hasn't set. team_update_settings() checks the same shape on the server.
window.RSTeam = (function () {
  // Features a manager can open to every member or keep to managers. "def" must match
  // team_feature_default() in SQL/rebuild_all.sql.
  var FEATURES = [
    { key: "strategy",     label: "Match Strategy", what: "draw and change match plans",         def: "members" },
    { key: "pit_crew",     label: "Pit Crew",       what: "log checklists, batteries and repairs", def: "members" },
    { key: "pick_list",    label: "Pick List",      what: "build and reorder the pick list",     def: "managers" },
    { key: "scout_shifts", label: "Scout Shifts",   what: "hand out scouting seats",             def: "managers" },
    { key: "share_codes",  label: "Share Codes",    what: "make share codes for people not on a team", def: "members" }
  ];

  // The pre-match checklist a team starts with. Saved checklists keep the items they had.
  var DEFAULT_CHECKLIST = [
    "Fresh battery in, strapped down, connector tight",
    "Bumpers on, right color, numbers showing",
    "Radio powered, ethernet and power plugs secure",
    "Main breaker on, no loose wires",
    "Mechanisms move freely, nothing rubbing",
    "Bolts on the drivetrain and intake checked",
    "Robot in its starting setup, preloaded game pieces",
    "Driver station charged, controllers plugged in, right auto picked"
  ];
  var DEFAULT_LOW_VOLTS = 12.5;   // a battery under this before a match is flagged

  function pit(info) { return (info && info.settings && info.settings.pit) || {}; }

  return {
    FEATURES: FEATURES,
    DEFAULT_CHECKLIST: DEFAULT_CHECKLIST,
    DEFAULT_LOW_VOLTS: DEFAULT_LOW_VOLTS,
    checklist: function (info) {
      var c = pit(info).checklist;
      return Array.isArray(c) && c.length ? c : DEFAULT_CHECKLIST;
    },
    lowVolts: function (info) {
      var v = Number(pit(info).low_volts);
      return v >= 10 && v <= 14 ? v : DEFAULT_LOW_VOLTS;
    },
    // Who can change a feature: "members" or "managers"
    permission: function (info, key) {
      var p = info && info.settings && info.settings.permissions;
      var f = FEATURES.find(function (x) { return x.key === key; });
      return (p && p[key]) || (f ? f.def : "managers");
    },
    // Can this person change it? Managers always can.
    can: function (info, key) {
      return !!(info && info.team_number && (info.role === "manager" || (info.can && info.can[key])));
    }
  };
})();
