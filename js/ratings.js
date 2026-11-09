// Rating math shared by the 1307scout pages: team grades, alliance grades, win chance, and the
// data they need. It's explained for users on ratings.html, which must change with this file.
// Needs js/teams.js loaded first.
(function () {
  var TIERS = {
    S:  { color: "#D4AF37", ink: "#2b2100" },
    A:  { color: "#1a7f4b", ink: "#ffffff" },
    B:  { color: "#1B4DB1", ink: "#ffffff" },
    C:  { color: "#6c3fb5", ink: "#ffffff" },
    D:  { color: "#e67e22", ink: "#ffffff" },
    F:  { color: "#c0392b", ink: "#ffffff" },
    NR: { color: "#9a9a9c", ink: "#ffffff" },
    TEST: { color: "#17a2b8", ink: "#ffffff" }
  };
  var CUTS = [[0.9, "S"], [0.75, "A"], [0.5, "B"], [0.25, "C"], [0.1, "D"]];
  var MIN_RATED_MATCHES = 3;
  var ALLIANCE_SIZE = 3;
  var MIN_SWING = 5;              // floor on a team's match-to-match swing, in points
  var WIN_LIMITS = [.05, .95];    // this data can't justify more certainty than this

  function num(v) {
    if (v == null || v === "") return null;
    var n = Number(v);
    return isFinite(n) ? n : null;
  }
  function mean(vals) {
    return vals.length ? vals.reduce(function (a, b) { return a + b; }, 0) / vals.length : null;
  }
  function tierFor(pct) {
    for (var i = 0; i < CUTS.length; i++) {
      if (pct >= CUTS[i][0]) return CUTS[i][1];
    }
    return "F";
  }
  // A rated row has enough matches and a score (an official score needs 3 qualification matches)
  function isRated(r) { return !!r && r.matches >= MIN_RATED_MATCHES && r.score != null; }
  function ratedRows(rows, testTeams) {
    return rows.filter(function (r) { return !testTeams.has(r.team_number) && isRated(r); });
  }
  // Same tiers and rules as query.html: where a team's score ranks among rated teams
  function gradeFor(rows, team, testTeams) {
    if (testTeams.has(team)) return "TEST";
    var me = rows.find(function (r) { return r.team_number === team; });
    if (!isRated(me)) return "NR";
    var rated = ratedRows(rows, testTeams), score = Number(me.score);
    return tierFor(rated.filter(function (r) { return Number(r.score) <= score; }).length / rated.length);
  }

  // Share of all possible 3-team alliances whose combined score is at or below total. Counted
  // exactly: for each pair, a binary search finds how many higher-placed teams complete it.
  function shareOfAlliances(scores, total) {
    var a = scores.slice().sort(function (x, y) { return x - y; });
    var n = a.length, count = 0;
    for (var i = 0; i < n - 2; i++) {
      for (var j = i + 1; j < n - 1; j++) {
        var limit = total - a[i] - a[j] + 1e-9;   // tolerance for decimal scores
        var lo = j + 1, hi = n;
        while (lo < hi) {
          var mid = (lo + hi) >> 1;
          if (a[mid] <= limit) lo = mid + 1; else hi = mid;
        }
        count += lo - (j + 1);
      }
    }
    return count / (n * (n - 1) * (n - 2) / 6);
  }
  // Scouting and official stay separate, as they do for teams. An alliance needs three rated
  // teams to get a grade, because a missing team would drag its total down.
  function allianceGrade(rows, teams, testTeams) {
    var rated = teams.length === ALLIANCE_SIZE && teams.every(function (t) {
      var g = gradeFor(rows, t, testTeams);
      return g !== "NR" && g !== "TEST";
    });
    if (!rated) return "NR";
    var pool = ratedRows(rows, testTeams).map(function (r) { return Number(r.score); });
    var total = teams.reduce(function (sum, t) {
      return sum + Number(rows.find(function (r) { return r.team_number === t; }).score);
    }, 0);
    return tierFor(shareOfAlliances(pool, total));
  }

  // Points a robot scored in each match, using the Table 6-4 values in rebuilt_points().
  // Entries for the same match are averaged, as they are in team_ratings().
  function pointsPerMatch(rows) {
    var byMatch = {};
    rows.forEach(function (r, i) {
      var key = r.match_number == null ? "entry" + i : r.event_id + "|" + r.match_number;
      var pts = (num(r.data.auto_fuel_hub) || 0) + (num(r.data.teleop_fuel_hub) || 0) +
        (r.data.auto_tower === "L1" ? 15 : 0) +
        ({ L1: 10, L2: 20, L3: 30 }[r.data.teleop_tower] || 0);
      (byMatch[key] = byMatch[key] || []).push(pts);
    });
    return Object.keys(byMatch).map(function (k) { return mean(byMatch[k]); });
  }
  // How far one future match could land from a team's average: its match-to-match variance,
  // plus 1/n more because an average of n matches is itself uncertain.
  function matchVariance(vals) {
    var n = vals.length;
    if (n < 2) return MIN_SWING * MIN_SWING;
    var avg = mean(vals);
    var variance = vals.reduce(function (s, v) { return s + (v - avg) * (v - avg); }, 0) / (n - 1);
    return Math.max(variance, MIN_SWING * MIN_SWING) * (1 + 1 / n);
  }
  // Red's chance when red is expected to lead by gap, with that much variance in the result.
  // The logistic curve is a close, standard stand-in for the normal distribution.
  function chanceFromGap(gap, variance) {
    return 1 / (1 + Math.exp(-1.702 * gap / Math.sqrt(variance)));
  }
  function hasMatches(t, source, testTeams) {
    return !testTeams.has(t.team) && isRated(t[source]);
  }
  // Scouted points are per robot, so the three robots add up, and so do their variances.
  function scoutedChance(red, blue, testTeams) {
    var all = red.concat(blue);
    if (!all.every(function (t) { return hasMatches(t, "scout", testTeams); })) return null;
    var sum = function (teams) {
      return teams.reduce(function (s, t) { return s + num(t.scout.avg_points); }, 0);
    };
    var variance = all.reduce(function (s, t) { return s + matchVariance(pointsPerMatch(t.rows)); }, 0);
    return chanceFromGap(sum(red) - sum(blue), variance);
  }
  // The official score is OPR (points a robot adds per match), so an alliance's expected score
  // is its three OPRs added up. Each side's variance is the average variance of its teams'
  // alliance scores, since those already describe a whole alliance's swing.
  function officialChance(red, blue, testTeams) {
    var all = red.concat(blue);
    if (!all.every(function (t) { return hasMatches(t, "official", testTeams); })) return null;
    var sum = function (teams) {
      return teams.reduce(function (s, t) { return s + num(t.official.score); }, 0);
    };
    var avgSpread = function (teams) {
      return teams.reduce(function (s, t) { return s + matchVariance(t.officialScores); }, 0) / teams.length;
    };
    return chanceFromGap(sum(red) - sum(blue), avgSpread(red) + avgSpread(blue));
  }
  // Red's chance overall and from each source, or null until all six teams have data.
  // red and blue are team objects from load().team().
  function winChance(red, blue, testTeams) {
    if (red.length < ALLIANCE_SIZE || blue.length < ALLIANCE_SIZE) return null;
    var scouted = scoutedChance(red, blue, testTeams), official = officialChance(red, blue, testTeams);
    var parts = [scouted, official].filter(function (p) { return p != null; });
    if (!parts.length) return null;
    return {
      overall: Math.min(WIN_LIMITS[1], Math.max(WIN_LIMITS[0], mean(parts))),
      scouted: scouted, official: official
    };
  }

  // ── Data ─────────────────────────────────────────────────────────
  // Same check as team_ratings(): skips entries from earlier seasons' forms.
  var SEASON_KEYS = ["stuck_on_field", "foul_or_card", "auto_fuel_hub", "teleop_fuel_hub", "auto_tower", "teleop_tower"];
  function isThisSeason(r) {
    return !!r.data && SEASON_KEYS.some(function (k) { return k in r.data; });
  }
  // The API returns at most 1000 rows per request, so page through anything that can grow.
  // One page first: most lists fit in it, and requesting pages past the end still costs the
  // database a full query each. Only a full page fetches the rest, 4 pages per round trip.
  async function pagedRows(query) {
    var size = 1000, batch = 4;
    var first = await query().range(0, size - 1);
    if (first.error) return { error: first.error, data: [] };
    var rows = first.data || [];
    if (rows.length < size) return { data: rows };
    for (var from = size; ; from += size * batch) {
      var pages = [];
      for (var k = 0; k < batch; k++) {
        pages.push(query().range(from + k * size, from + (k + 1) * size - 1));
      }
      var res = await Promise.all(pages);
      for (var j = 0; j < res.length; j++) {
        if (res[j].error) return { error: res[j].error, data: rows };
        rows = rows.concat(res[j].data || []);
        if ((res[j].data || []).length < size) return { data: rows };
      }
    }
  }

  // The per-team lists, by name, as { name: { data } or { error } }, from one team_lists() call
  // (SQL/rebuild_all.sql). Until that function is installed, each list comes from its own call.
  var LIST_RPC = {
    ratings: "team_ratings", official_ratings: "team_official_ratings",
    data_counts: "team_data_counts", official_summary: "team_official_summary"
  };
  var haveTeamLists = true;
  async function lists(sb, parts) {
    if (haveTeamLists) {
      var r = await sb.rpc("team_lists", { p_parts: parts });
      if (!r.error) {
        var out = {};
        parts.forEach(function (p) { out[p] = { data: (r.data && r.data[p]) || [] }; });
        return out;
      }
      if (r.error.code !== "PGRST202" && !/could not find the function/i.test(r.error.message || "")) {
        var failed = {};
        parts.forEach(function (p) { failed[p] = { error: r.error, data: [] }; });
        return failed;
      }
      haveTeamLists = false;   // not installed yet: fall back for the rest of this visit
    }
    var res = await Promise.all(parts.map(function (p) {
      if (p === "pit_teams") {
        return pagedRows(function () { return sb.from("pit_entries").select("team_number").order("id"); })
          .then(function (x) {
            return x.error ? x : { data: Array.from(new Set(x.data.map(function (row) { return row.team_number; }))) };
          });
      }
      return pagedRows(function () { return sb.rpc(LIST_RPC[p]).order("team_number"); });
    }));
    var byName = {};
    parts.forEach(function (p, i) { byName[p] = res[i]; });
    return byName;
  }

  // Everything the grades and win chance need for these teams. failed lists any request that
  // didn't load, since that would otherwise look like a team with no data.
  async function load(sb, teams) {
    var any = teams.length > 0;
    var ranked = lists(sb, ["ratings", "official_ratings"]);
    var results = await Promise.all([
      ranked.then(function (l) { return l.ratings; }),
      ranked.then(function (l) { return l.official_ratings; }),
      sb.from("test_teams").select("team_number"),
      any ? RSTeams.loadInfo(sb, teams) : { info: {} },
      any ? pagedRows(function () {
        return sb.from("scouting_entries").select("team_number,event_id,match_number,data")
          .in("team_number", teams).order("id");
      }) : { data: [] },
      any ? sb.from("pit_entries").select("team_number,data,updated_at").in("team_number", teams)
          .order("updated_at", { ascending: false }) : { data: [] },
      any ? pagedRows(function () {
        return sb.rpc("official_match_teams_for", { p_teams: teams })
          .select("team_number,event_id,match_key,alliance_score,opponent_score")   // match_key too: PostgREST only sorts a function result by selected columns
          .order("event_id").order("match_key").order("team_number");
      }) : { data: [] }
    ]);
    var d = {
      failed: results.filter(function (r) { return r.error; }).map(function (r) { return r.error; }),
      ratings: results[0].data || [],
      officialRatings: results[1].data || [],
      testTeams: new Set((results[2].data || []).map(function (t) { return t.team_number; })),
      teamInfo: results[3].info || {},
      entries: {}, pits: {}, games: {}
    };
    (results[4].data || []).filter(isThisSeason).forEach(function (r) {
      (d.entries[r.team_number] = d.entries[r.team_number] || []).push(r);
    });
    (results[5].data || []).forEach(function (p) {
      if (!d.pits[p.team_number]) d.pits[p.team_number] = p;   // newest first
    });
    (results[6].data || []).forEach(function (r) {
      if (r.alliance_score == null || r.opponent_score == null) return;   // not played yet
      (d.games[r.team_number] = d.games[r.team_number] || []).push(r);
    });
    // One team's data, in the shape gradeFor and winChance expect
    d.team = function (team) {
      var games = d.games[team] || [];
      return {
        team: team,
        info: d.teamInfo[team] || {},
        scout: d.ratings.find(function (r) { return r.team_number === team; }) || null,
        official: d.officialRatings.find(function (r) { return r.team_number === team; }) || null,
        gradeScout: gradeFor(d.ratings, team, d.testTeams),
        gradeOfficial: gradeFor(d.officialRatings, team, d.testTeams),
        rows: d.entries[team] || [],
        games: games,
        officialScores: games.map(function (g) { return g.alliance_score; }),
        pit: d.pits[team] || null
      };
    };
    return d;
  }

  // A letter grade badge. size "sm" is the compact one used in tables and lists.
  function gradeBadge(tier, label) {
    var c = TIERS[tier];
    return '<span class="rs-grade" style="background:' + c.color + ";color:" + c.ink + ';"' +
      (label ? ' title="' + label + ": " + tier + '"' : "") + ">" + (tier === "TEST" ? "T" : tier) + "</span>";
  }

  window.RSRatings = {
    TIERS: TIERS, MIN_RATED_MATCHES: MIN_RATED_MATCHES, SEASON_KEYS: SEASON_KEYS,
    num: num, mean: mean, gradeFor: gradeFor, allianceGrade: allianceGrade,
    pointsPerMatch: pointsPerMatch, winChance: winChance,
    isThisSeason: isThisSeason, pagedRows: pagedRows, lists: lists, load: load, gradeBadge: gradeBadge
  };
})();
