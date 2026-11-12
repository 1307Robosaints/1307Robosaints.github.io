// An event's match schedule for the 1307scout pages that need it (Scout Shifts, Scout, the home
// page): the synced official matches with the hand edits from Our Matches laid over them, in
// play order. Match keys are the official sync's: qm12, sf5m1, f1m2. Needs js/ratings.js.
(function () {
  var LEVEL_ORDER = { qm: 0, sf: 1, f: 2 };
  var STATIONS = ["red1", "red2", "red3", "blue1", "blue2", "blue3"];

  function parseKey(key) {
    var m = /^(qm)(\d+)$|^sf(\d+)m(\d+)$|^f1m(\d+)$/.exec(key || "");
    if (!m) return null;
    if (m[1]) return { level: "qm", n: +m[2], game: 1 };
    if (m[3]) return { level: "sf", n: +m[3], game: +m[4] };
    return { level: "f", n: +m[5], game: 1 };
  }
  function label(key) {
    var k = parseKey(key);
    if (!k) return key;
    return k.level === "qm" ? "Qual " + k.n : k.level === "sf" ? "Playoff " + k.n + (k.game > 1 ? " replay" : "") : "Final " + k.n;
  }
  function compare(a, b) {
    var x = parseKey(a), y = parseKey(b);
    return LEVEL_ORDER[x.level] - LEVEL_ORDER[y.level] || x.n - y.n || x.game - y.game;
  }
  // Unplayed matches can come through as null, 0-0 or TBA's -1
  function isPlayed(m) {
    return !!m && m.red_score != null && m.blue_score != null && m.red_score >= 0 && m.blue_score >= 0 &&
      (m.red_score > 0 || m.blue_score > 0);
  }
  function stationLabel(st) { return st.charAt(0).toUpperCase() + st.slice(1, -1) + " " + st.slice(-1); }
  // The team in a seat ("red2") of a match, or null
  function teamAt(m, st) {
    var side = st.slice(0, -1), i = Number(st.slice(-1)) - 1;
    return (m[side + "_teams"] || [])[i] || null;
  }

  // { matches: [...] in play order, error }. Each match has match_key, red_teams, blue_teams,
  // red_score, blue_score, time, played, and source ("official", "edited" or "manual").
  async function load(sb, eventId) {
    var res = await Promise.all([
      RSRatings.pagedRows(function () {
        return sb.from("official_matches_combined")
          .select("match_key,red_teams,blue_teams,red_score,blue_score,played_at")
          .eq("event_id", eventId).order("match_key");
      }),
      sb.from("match_schedule").select("match_key,red_teams,blue_teams,scheduled_at").eq("event_id", eventId)
    ]);
    var official = {}, edits = {};
    (res[0].data || []).forEach(function (m) { official[m.match_key] = m; });
    (res[1].data || []).forEach(function (m) { edits[m.match_key] = m; });
    var keys = Object.keys(Object.assign({}, official, edits)).filter(parseKey).sort(compare);
    var matches = keys.map(function (key) {
      var o = official[key], e = edits[key];
      var m = Object.assign({ match_key: key }, o || {});
      if (e) {
        m.red_teams = e.red_teams;
        m.blue_teams = e.blue_teams;
        m.time = e.scheduled_at || (o ? o.played_at : null);
        m.source = o ? "edited" : "manual";
      } else {
        m.time = o.played_at;
        m.source = "official";
      }
      m.played = isPlayed(m);
      return m;
    });
    return { matches: matches, error: res[0].error || res[1].error || null };
  }

  window.RSSchedule = {
    STATIONS: STATIONS, parseKey: parseKey, label: label, compare: compare, isPlayed: isPlayed,
    stationLabel: stationLabel, teamAt: teamAt, load: load
  };
})();
