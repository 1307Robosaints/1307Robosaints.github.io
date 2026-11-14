// The 2026 FRC 8-alliance double-elimination playoff bracket, shared by bracket.html (the full
// page, where staff also settle ties and line-ups) and live.html (Competition Day, read-only).
//   load(sb, eventId)  an event's alliances, playoff results, tiebreaks and line-ups
//   make(data)         a bracket over that data: resolve() works out who plays and who won,
//                      html(results, opts) draws it, upcoming(results) lists matches still to play
// Round 1 fills from playoff_picks; official results (sf1-sf13, f1) move alliances along,
// matched on team numbers rather than trusting the colors. Needs js/teams.js.
(function () {
  // ── The format ─────────────────────────────────────────────────────
  // Each side is a seed, or the winner or loser of an earlier match, in official red/blue order.
  // col is the round (0 = Round 1), y the top of the card. If FIRST changes the format, edit this.
  var seed = function (n) { return { seed: n }; };
  var won = function (n) { return { won: n }; };
  var lost = function (n) { return { lost: n }; };
  var MATCHES = [
    { n: 1,  red: seed(1), blue: seed(8), col: 0, y: 50 },
    { n: 2,  red: seed(4), blue: seed(5), col: 0, y: 145 },
    { n: 3,  red: seed(2), blue: seed(7), col: 0, y: 240 },
    { n: 4,  red: seed(3), blue: seed(6), col: 0, y: 335 },
    { n: 7,  red: won(1),  blue: won(2),  col: 1, y: 97 },
    { n: 8,  red: won(3),  blue: won(4),  col: 1, y: 287 },
    { n: 11, red: won(7),  blue: won(8),  col: 3, y: 192 },
    { n: 5,  red: lost(1), blue: lost(2), col: 1, y: 480 },
    { n: 6,  red: lost(3), blue: lost(4), col: 1, y: 575 },
    { n: 10, red: lost(8), blue: won(5),  col: 2, y: 480 },
    { n: 9,  red: lost(7), blue: won(6),  col: 2, y: 575 },
    { n: 12, red: won(10), blue: won(9),  col: 3, y: 527 },
    { n: 13, red: lost(11), blue: won(12), col: 4, y: 527 }
  ];
  var FINAL = { red: won(11), blue: won(13), col: 5, y: 345 };
  var FINAL_WINS = 2;   // best of 3

  var CARD_W = 192, CARD_H = 76, FINAL_H = 96, COL = 224;
  var CANVAS_H = 680, CANVAS_W = COL * 5 + CARD_W;
  var ROUNDS = ["Round 1", "Round 2", "Round 3", "Round 4", "Round 5", "Finals"];
  var BYE = 0;   // stands in for an empty alliance

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  // Unplayed matches can come through as null, 0-0 or TBA's -1, so none of those count as played.
  function played(g) {
    return g.red_score != null && g.blue_score != null && g.red_score >= 0 && g.blue_score >= 0 &&
      (g.red_score > 0 || g.blue_score > 0);
  }
  // Sorts official matches into "sf8" or "f1" lists, by match_key (see section 8 of rebuild_all.sql)
  function groupGames(rows) {
    var out = {};
    rows.forEach(function (g) {
      var m = /^(sf|f)(\d+)m(\d+)$/.exec(g.match_key || "");
      if (!m || !played(g)) return;
      g.replay = Number(m[3]);
      (out[m[1] + m[2]] = out[m[1] + m[2]] || []).push(g);
    });
    Object.keys(out).forEach(function (k) {
      out[k].sort(function (a, b) { return a.replay - b.replay; });
    });
    return out;
  }

  // ── Loading ────────────────────────────────────────────────────────
  // { picks, games, tiebreaks, lineups, error }. error is the first failed request, if any.
  async function load(sb, eventId) {
    var res = await Promise.all([
      sb.from("playoff_picks").select("alliance_number,slot,team_number,source").eq("event_id", eventId),
      sb.from("official_matches_combined")
        .select("match_key,red_teams,blue_teams,red_score,blue_score")
        .eq("event_id", eventId).in("comp_level", ["sf", "f"]),
      sb.from("playoff_tiebreaks").select("match_key,winner_alliance").eq("event_id", eventId),
      sb.from("playoff_lineups").select("match_key,alliance_number,sits_out").eq("event_id", eventId)
    ]);
    var failed = res.filter(function (r) { return r.error; });
    var tiebreaks = {}, lineups = {};
    (res[2].data || []).forEach(function (t) { tiebreaks[t.match_key] = t.winner_alliance; });
    (res[3].data || []).forEach(function (l) { lineups[l.match_key + "|" + l.alliance_number] = l; });
    return {
      picks: res[0].data || [], games: groupGames(res[1].data || []),
      tiebreaks: tiebreaks, lineups: lineups,
      error: failed.length ? failed[0].error : null
    };
  }

  // ── One bracket ────────────────────────────────────────────────────
  function make(data) {
    var picks = data.picks || [], games = data.games || {};
    var tiebreaks = data.tiebreaks || {}, lineups = data.lineups || {};

    function teamsOf(a) {
      return picks.filter(function (p) { return p.alliance_number === a; })
        .sort(function (x, y) { return x.slot - y.slot; })
        .map(function (p) { return p.team_number; });
    }
    // Fewer than 8 alliances: once every alliance above it has at least 3 teams, an empty alliance
    // is a bye, and whoever it would have played moves on without playing.
    function isBye(n) {
      if (!picks.length || teamsOf(n).length) return false;
      for (var a = 1; a < n; a++) if (teamsOf(a).length < 3) return false;
      return true;
    }
    function overlap(teams, list) {
      return teams.filter(function (t) { return (list || []).indexOf(t) !== -1; }).length;
    }
    // Scores and teams for each alliance, matched on team numbers instead of trusting the colors.
    // A backup robot still leaves two teams to match on. Returns null if they don't fit either way.
    function sidesFor(redAlliance, blueAlliance, g) {
      var red = teamsOf(redAlliance), blue = teamsOf(blueAlliance);
      var same = overlap(red, g.red_teams) + overlap(blue, g.blue_teams);
      var swapped = overlap(red, g.blue_teams) + overlap(blue, g.red_teams);
      if (same === swapped) return null;
      return same > swapped
        ? { red: g.red_score, blue: g.blue_score, redTeams: g.red_teams, blueTeams: g.blue_teams }
        : { red: g.blue_score, blue: g.red_score, redTeams: g.blue_teams, blueTeams: g.red_teams };
    }
    // A 4-team alliance plays three: the captain plus two. No choice saved means the 3rd pick sits out.
    function plannedTeams(alliance, key) {
      var teams = teamsOf(alliance);
      if (teams.length < 4) return teams;
      var row = lineups[key + "|" + alliance];
      var out = row && teams.indexOf(row.sits_out) > 0 ? row.sits_out : teams[3];
      return teams.filter(function (t) { return t !== out; });
    }
    // The winning alliance of a tied match, if staff entered the tiebreaker, else null
    function tiebreakWinner(key, a, b) {
      var w = tiebreaks[key];
      return w === a || w === b ? w : null;
    }

    // Every match's alliances, scores and winner, by match number, plus results.final
    function resolve() {
      var results = {};
      function allianceFor(side) {
        if (side.seed) return isBye(side.seed) ? BYE : side.seed;
        if (side.won) return results[side.won].winner;
        return results[side.lost].loser;
      }
      // Sorted by number, because a match only ever depends on lower-numbered ones
      MATCHES.slice().sort(function (a, b) { return a.n - b.n; }).forEach(function (m) {
        var key = "sf" + m.n;
        var r = results[m.n] = { n: m.n, key: key, red: allianceFor(m.red), blue: allianceFor(m.blue), winner: null, loser: null, flag: "" };
        if (r.red != null) r.redTeams = plannedTeams(r.red, key);
        if (r.blue != null) r.blueTeams = plannedTeams(r.blue, key);
        if (r.red === BYE || r.blue === BYE) {
          var other = r.red === BYE ? r.blue : r.red;
          if (other == null) return;               // waiting on an earlier match
          r.bye = true;
          r.winner = other;
          r.loser = BYE;
          return;
        }
        var list = games[key];
        if (!list || r.red == null || r.blue == null) return;
        var g = list[list.length - 1];   // a replay replaces the earlier result
        var sides = sidesFor(r.red, r.blue, g);
        if (!sides) { r.flag = "Official teams don't match"; return; }
        r.played = true;
        r.redScore = sides.red;
        r.blueScore = sides.blue;
        r.redTeams = sides.redTeams;
        r.blueTeams = sides.blueTeams;
        if (sides.red === sides.blue) {
          r.tie = g.match_key;
          r.winner = tiebreakWinner(g.match_key, r.red, r.blue);
          if (r.winner == null) return;
        } else {
          r.winner = sides.red > sides.blue ? r.red : r.blue;
        }
        r.loser = r.winner === r.red ? r.blue : r.red;
      });

      var f = { red: allianceFor(FINAL.red), blue: allianceFor(FINAL.blue), redWins: 0, blueWins: 0, scores: [], winner: null, flag: "" };
      if ((f.red === BYE || f.blue === BYE) && f.red != null && f.blue != null) {
        f.winner = f.red === BYE ? f.blue : f.red;
      } else if (f.red != null && f.blue != null) {
        (games.f1 || []).forEach(function (g) {
          var sides = sidesFor(f.red, f.blue, g);
          if (!sides) { f.flag = "Official teams don't match"; return; }
          var w = sides.red > sides.blue ? f.red : sides.blue > sides.red ? f.blue : tiebreakWinner(g.match_key, f.red, f.blue);
          if (sides.red === sides.blue && w == null && !f.tie) f.tie = g.match_key;
          f.scores.push(sides.red + "–" + sides.blue + (sides.red === sides.blue ? (w == null ? " tie" : " (A" + w + ")") : ""));
          if (w === f.red) f.redWins++;
          if (w === f.blue) f.blueWins++;
        });
        if (f.redWins >= FINAL_WINS) f.winner = f.red;
        else if (f.blueWins >= FINAL_WINS) f.winner = f.blue;
        f.key = "f1m" + (f.scores.length + 1);   // the next finals game, for its line-up
        f.redTeams = plannedTeams(f.red, f.key);
        f.blueTeams = plannedTeams(f.blue, f.key);
      }
      results.final = f;
      return results;
    }

    // Matches still to play whose alliances are both known, in play order (1 to 13, then the
    // finals): { key (official match key, e.g. sf5m1), label, red, blue (alliance numbers),
    // red_teams, blue_teams }. A tied match waiting on its tiebreaker isn't listed.
    function upcoming(results) {
      var out = [];
      for (var n = 1; n <= 13; n++) {
        var r = results[n];
        if (!r || r.bye || r.played || r.winner != null || r.red == null || r.blue == null || r.flag) continue;
        out.push({ key: "sf" + n + "m1", label: "Playoff " + n, red: r.red, blue: r.blue, red_teams: r.redTeams, blue_teams: r.blueTeams });
      }
      var f = results.final;
      if (f && f.winner == null && f.red != null && f.blue != null && f.red !== BYE && f.blue !== BYE && !f.tie && !f.flag) {
        out.push({ key: f.key, label: "Final " + (f.scores.length + 1), red: f.red, blue: f.blue, red_teams: f.redTeams, blue_teams: f.blueTeams });
      }
      return out;
    }
    // The alliance number a team is on, or null
    function allianceOf(team) {
      var p = picks.find(function (x) { return x.team_number === team; });
      return p ? p.alliance_number : null;
    }

    // ── Drawing ──────────────────────────────────────────────────────
    // opts: { canEdit (staff controls for ties and line-ups), ourTeam, teamInfo, compact (no
    // staff controls and no Compare links, for embedding) }. Returns the canvas's inner HTML;
    // size the canvas to RSBracket.WIDTH x RSBracket.HEIGHT.
    function html(results, opts) {
      opts = opts || {};
      var canEdit = !!opts.canEdit && !opts.compact, teamInfo = opts.teamInfo || {};
      function teamLabel(t) { return RSTeams.label(t, teamInfo[t]); }

      function waitingText(side) {
        return side.seed ? "Not picked yet"
          : side.won ? "Winner of Match " + side.won : "Loser of Match " + side.lost;
      }
      // The alliance's teams. Teams not in this match are struck through, and for a match still to
      // play, staff can click a teammate of the captain to have them sit out.
      function teamsHtml(alliance, playing, key, editable) {
        var all = teamsOf(alliance);
        var label = all.map(teamLabel).join(", ");
        return '<span class="b-teams" title="' + esc(label) + '">' + all.map(function (t, i) {
          var out = playing && playing.indexOf(t) === -1;
          var tip = esc(teamLabel(t)) + (out ? " (sits out)" : "");
          if (editable && all.length === 4 && i > 0 && !out) {
            return '<button type="button" class="b-t" data-sit="' + t + '" data-a="' + alliance + '" data-key="' + key +
              '" title="' + tip + ' – click to have this team sit out">' + t + "</button>";
          }
          return '<span class="b-t' + (out ? " out" : "") + '" title="' + tip + '">' + t + "</span>";
        }).join(" ") + "</span>";
      }
      function sideHtml(color, side, alliance, r, extra) {
        var teams = alliance == null ? [] : teamsOf(alliance);
        var cls = "b-side " + color;
        if (r.winner != null) cls += alliance === r.winner ? " won" : " lost";
        if (opts.ourTeam && teams.indexOf(opts.ourTeam) !== -1) cls += " ours";
        var playing = color === "red" ? r.redTeams : r.blueTeams;
        var editable = canEdit && !r.played && r.winner == null;
        if (alliance === BYE) return '<div class="b-side ' + color + ' lost"><span class="b-wait">Bye</span></div>';
        return '<div class="' + cls + '">' +
          (alliance == null ? "" : '<span class="b-seed" title="Alliance ' + alliance + '">A' + alliance + "</span>") +
          (teams.length ? teamsHtml(alliance, playing, r.key, editable)
            : '<span class="b-wait">' + esc(waitingText(side)) + "</span>") +
          (extra == null ? "" : '<span class="b-score">' + extra + "</span>") +
        "</div>";
      }
      // Opens the match-up in the Alliance View, with the three teams each side plays
      function compareLink(r) {
        if (opts.compact || !r.redTeams || !r.blueTeams || !r.redTeams.length || !r.blueTeams.length) return "";
        return '<a class="b-compare" href="/alliance.html?red=' + r.redTeams.slice(0, 3).join(",") + "&blue=" +
          r.blueTeams.slice(0, 3).join(",") + '" title="Open this match-up in the Alliance View">Compare</a>';
      }
      // A tied match waits for the tiebreaker. Staff say who won it, and can undo that.
      function tieHtml(key, a, b, winner) {
        if (winner != null) {
          return '<div class="b-flag">A' + winner + " won the tiebreaker" +
            (canEdit ? ' <button type="button" data-untie="' + key + '">Undo</button>' : "") + "</div>";
        }
        if (!canEdit) return '<div class="b-flag">Tied, waiting on the tiebreaker</div>';
        return '<div class="b-flag">Tied. Who won? ' +
          '<button type="button" data-tie="' + key + '" data-winner="' + a + '">A' + a + "</button> " +
          '<button type="button" data-tie="' + key + '" data-winner="' + b + '">A' + b + "</button></div>";
      }
      function cardStyle(col, y, h) {
        return "left:" + col * COL + "px;top:" + y + "px;width:" + CARD_W + "px;min-height:" + h + "px;";
      }
      function matchHtml(m, r) {
        return '<div class="b-match" id="match' + m.n + '" style="' + cardStyle(m.col, m.y, CARD_H) + '">' +
          '<div class="b-match-head"><span>Match ' + m.n + "</span>" + compareLink(r) + "</div>" +
          sideHtml("red", m.red, r.red, r, r.redScore) +
          sideHtml("blue", m.blue, r.blue, r, r.blueScore) +
          (r.tie ? tieHtml(r.tie, r.red, r.blue, r.winner)
            : r.flag ? '<div class="b-flag" title="' + esc(r.flag) + '">' + esc(r.flag) + "</div>" : "") +
        "</div>";
      }
      function finalHtml(f) {
        var started = f.scores.length > 0;
        var shown = Object.assign({}, f, { winner: f.winner, played: f.winner != null });
        return '<div class="b-match final" id="matchFinal" style="' + cardStyle(FINAL.col, FINAL.y, FINAL_H) + '">' +
          '<div class="b-match-head"><span>Finals, best of 3</span>' + (f.winner == null ? compareLink(f) : "") + "</div>" +
          sideHtml("red", FINAL.red, f.red, shown, started ? f.redWins : null) +
          sideHtml("blue", FINAL.blue, f.blue, shown, started ? f.blueWins : null) +
          (started ? '<div class="b-games">' + esc(f.scores.join(", ")) + "</div>" : "") +
          (f.tie ? tieHtml(f.tie, f.red, f.blue, null) : f.flag ? '<div class="b-flag">' + esc(f.flag) + "</div>" : "") +
        "</div>";
      }
      function champHtml(f) {
        if (f.winner == null) return "";
        return '<div class="b-champ" id="champion" style="left:' + FINAL.col * COL + "px;top:" + (FINAL.y + FINAL_H + 30) + "px;width:" + CARD_W + 'px;">' +
          "<span>Event winners</span><strong>Alliance " + f.winner + "</strong><em>" + esc(teamsOf(f.winner).join("  ")) + "</em></div>";
      }
      // Lines follow winners only. Losers drop down by name, as on FIRST's own bracket.
      function linesHtml() {
        var byNumber = {};
        MATCHES.forEach(function (m) { byNumber[m.n] = m; });
        var paths = "";
        function link(from, to, toHeight) {
          var x1 = from.col * COL + CARD_W, y1 = from.y + CARD_H / 2;
          var x2 = to.col * COL, y2 = to.y + toHeight / 2;
          var mid = x2 - (COL - CARD_W) / 2;
          paths += '<path d="M' + x1 + " " + y1 + " H" + mid + " V" + y2 + " H" + x2 + '"/>';
        }
        MATCHES.forEach(function (m) {
          [m.red, m.blue].forEach(function (side) {
            if (side.won) link(byNumber[side.won], m, CARD_H);
          });
        });
        link(byNumber[FINAL.red.won], FINAL, FINAL_H);
        link(byNumber[FINAL.blue.won], FINAL, FINAL_H);
        return '<svg class="b-lines" width="' + CANVAS_W + '" height="' + CANVAS_H + '" aria-hidden="true">' + paths + "</svg>";
      }

      var heads = ROUNDS.map(function (name, i) {
        return '<div class="b-round" style="left:' + i * COL + "px;width:" + CARD_W + 'px;">' + name + "</div>";
      }).join("");
      return linesHtml() + heads +
        '<div class="b-section" style="top:22px;">Upper bracket</div>' +
        '<div class="b-section" style="top:450px;">Lower bracket</div>' +
        MATCHES.map(function (m) { return matchHtml(m, results[m.n]); }).join("") +
        finalHtml(results.final) + champHtml(results.final);
    }

    return {
      picks: picks, teamsOf: teamsOf, isBye: isBye, allianceOf: allianceOf,
      resolve: resolve, upcoming: upcoming, html: html
    };
  }

  window.RSBracket = {
    MATCHES: MATCHES, FINAL: FINAL, WIDTH: CANVAS_W, HEIGHT: CANVAS_H,
    played: played, load: load, make: make
  };
})();
