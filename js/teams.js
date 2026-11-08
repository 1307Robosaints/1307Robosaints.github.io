// Team names and logos across 1307scout, shown as "1678 Citrus Circuits". A page reads team_info's
// display_name and display_logo (what staff set, or else what came from TBA). For teams never
// looked up, or not in 30 days, fillMissing() asks the team-names Edge Function to look them up
// on The Blue Alliance.
(function () {
  var TRIED_KEY = "rs_names_tried";   // teams already looked up in this browser session
  var CHUNK = 60;                     // the Edge Function takes up to 60 teams per call
  var RECHECK_MS = 30 * 864e5;        // same 30 days the Edge Function uses

  function tried() {
    try { return JSON.parse(sessionStorage.getItem(TRIED_KEY)) || []; } catch (e) { return []; }
  }
  function markTried(teams) {
    try { sessionStorage.setItem(TRIED_KEY, JSON.stringify(tried().concat(teams).slice(-3000))); } catch (e) {}
  }
  // The API returns at most 1000 rows per request, and team_info grows with every team seen
  async function pagedInfo(sb, teams) {
    var rows = [], size = 1000;
    for (var from = 0; ; from += size) {
      var q = sb.from("team_info").select("team_number,team_name,tba_name,display_name,logo_url,display_logo,tba_checked_at").order("team_number");
      if (teams) q = q.in("team_number", teams);
      var r = await q.range(from, from + size - 1);
      if (r.error) return { error: r.error, data: rows };
      rows = rows.concat(r.data || []);
      if ((r.data || []).length < size) return { data: rows };
    }
  }

  window.RSTeams = {
    // team_info rows as { team_number: row }, for the teams given, or every team
    loadInfo: async function (sb, teams) {
      var r = await pagedInfo(sb, teams && teams.length > 300 ? null : teams);
      var map = {};
      (r.data || []).forEach(function (t) { map[t.team_number] = t; });
      return { error: r.error || null, info: map };
    },
    name: function (info) { return (info && info.display_name) || ""; },
    logo: function (info) { return (info && info.display_logo) || ""; },
    label: function (team, info) {
      var n = info && info.display_name;
      return n ? team + " " + n : String(team);
    },
    // Looks up the given teams that are due a TBA lookup, adds the names and logos it finds into
    // infoMap, and resolves to true if anything was added (so the page can redraw).
    fillMissing: async function (sb, teams, infoMap) {
      var done = tried();
      var missing = Array.from(new Set(teams)).filter(function (t) {
        var i = infoMap[t];
        var due = !i || !i.tba_checked_at || Date.now() - Date.parse(i.tba_checked_at) > RECHECK_MS;
        return Number.isInteger(t) && t > 0 && due && done.indexOf(t) === -1;
      });
      if (!missing.length) return false;
      markTried(missing);
      var added = false;
      for (var i = 0; i < missing.length; i += CHUNK) {
        var r = await sb.functions.invoke("team-names", { body: { teams: missing.slice(i, i + CHUNK) } });
        if (r.error || !r.data || !r.data.teams) {
          console.warn("Team names:", r.error ? r.error.message : "no reply");
          return added;
        }
        Object.keys(r.data.teams).forEach(function (k) {
          var team = Number(k), found = r.data.teams[k], row = infoMap[team] || { team_number: team };
          var before = row.display_name + "|" + row.display_logo;
          row.tba_name = found.name;
          row.tba_logo_url = found.logo;
          row.tba_checked_at = new Date().toISOString();
          row.display_name = row.team_name || found.name || null;
          row.display_logo = row.logo_url || found.logo || null;
          infoMap[team] = row;
          if (row.display_name + "|" + row.display_logo !== before) added = true;
        });
      }
      return added;
    }
  };
})();
