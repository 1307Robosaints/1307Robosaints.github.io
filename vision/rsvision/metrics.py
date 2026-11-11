"""From robot tracks to per-robot numbers. Pure numpy, so it's tested without video (tests/).

Field coordinates are inches with x = 0 at the red alliance wall and y = 0 on the
scoring-table side, set by the calibration. Times are match seconds (see timeline.MatchClock).

The keys saved in vision_robots.data must stay in step with js/vision.js and ratings.html.
"""
from collections import Counter, defaultdict
from dataclasses import dataclass, field

import numpy as np


@dataclass
class Tracklet:
    """One unbroken track from the tracker: a robot seen in consecutive wide-shot frames."""
    id: int
    color: str                                   # "red" or "blue", from the bumper class
    t: list = field(default_factory=list)        # match seconds
    xy: list = field(default_factory=list)       # field inches
    votes: Counter = field(default_factory=Counter)   # team number -> bumper-number read score
    looks: list = field(default_factory=list)    # appearance vectors (appearance.Embedder), about 1 a second

    @property
    def start(self):
        return self.t[0]

    @property
    def end(self):
        return self.t[-1]


# ── Bumper numbers ────────────────────────────────────────────────
def _edit_distance(a, b):
    d = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        prev, d[0] = d[0], i
        for j, cb in enumerate(b, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (ca != cb))
    return d[-1]


def match_number(text, candidates, conf=1.0):
    """Which of an alliance's teams a bumper read most likely is, as (team, score) or None.

    Only the three teams on that alliance are possible, so a partly misread number still
    picks the right team when it's closer to one of them than the others.
    """
    digits = "".join(ch for ch in str(text) if ch.isdigit())
    if not digits or not candidates:
        return None
    scored = []
    for team in candidates:
        s = str(team)
        sim = 1 - _edit_distance(digits, s) / max(len(digits), len(s))
        scored.append((sim, team))
    scored.sort(reverse=True)
    best, team = scored[0]
    runner_up = scored[1][0] if len(scored) > 1 else 0
    if best < 0.6 or best - runner_up < 0.2:
        return None
    return team, best * conf


# ── Who's who ─────────────────────────────────────────────────────
def _overlap(a, b, slack=0.5):
    return a.start < b.end - slack and b.start < a.end - slack


def stitch(tracklets, max_gap_s=4.0, max_speed=240.0, slack_in=36.0):
    """Joins tracklets that are probably one robot: same color, one starts soon after the
    other ends, close enough that a robot could have driven there. Returns chains (lists)."""
    order = sorted(tracklets, key=lambda k: k.start)
    chains = []
    for k in order:
        best, best_gap = None, None
        for ch in chains:
            last = ch[-1]
            gap = k.start - last.end
            if last.color != k.color or not (0 <= gap <= max_gap_s):
                continue
            if any(_overlap(k, other) for other in ch):
                continue
            dist = float(np.hypot(*(np.asarray(k.xy[0]) - np.asarray(last.xy[-1]))))
            if dist <= gap * max_speed + slack_in and (best_gap is None or gap < best_gap):
                best, best_gap = ch, gap
        if best is not None:
            best.append(k)
        else:
            chains.append([k])
    return chains


# For the ImageNet look model, tuned on 2026matb (10 matches, leave-one-match-out on clearly read
# robots): 9 of 9 decided were right. A fine-tuned model brings its own (appearance.thresholds).
LOOK_MIN = 0.90      # lowest look similarity that can identify a robot
LOOK_MARGIN = 0.03   # and how far it must beat the next-best team on the alliance


def _votes(ch):
    votes = Counter()
    for k in ch:
        votes.update(k.votes)
    return votes


def assign_teams(chains, lineup, look=None):
    """Gives each chain a team from its alliance's line-up, in three steps:

    1. "number": chains with bumper-number votes, strongest first. Two chains seen at the
       same time can't be the same robot.
    2. "look": with look(chain, team) -> similarity (appearance.Gallery.matcher), an unread
       chain takes the team whose robot it looks most like, when the match is close enough
       and clearly better than the next team.
    3. "left": a chain still unassigned takes the only team of its color it could still be.

    Returns ({chain index: team}, {chain index: "number" | "look" | "left"}).
    """
    def span(ch):
        return min(k.start for k in ch), max(k.end for k in ch)

    def clash(i, j):
        a, b = span(chains[i]), span(chains[j])
        return a[0] < b[1] - 0.5 and b[0] < a[1] - 0.5

    owner, how = {}, {}
    taken = defaultdict(list)   # team -> chain indexes

    def free(i):
        return [t for t in lineup.get(chains[i][0].color, []) if not any(clash(i, j) for j in taken[t])]

    def give(i, team, why):
        owner[i], how[i] = team, why
        taken[team].append(i)

    offers = []
    for i, ch in enumerate(chains):
        for team, score in _votes(ch).items():
            if team in lineup.get(ch[0].color, []):
                offers.append((score, i, team))
    for score, i, team in sorted(offers, reverse=True):
        if i not in owner and not any(clash(i, j) for j in taken[team]):
            give(i, team, "number")

    if look is not None:
        lo, gap = getattr(look, "thresholds", (LOOK_MIN, LOOK_MARGIN))
        offers = []
        for i, ch in enumerate(chains):
            if i in owner:
                continue
            sims = sorted(((s, t) for t in free(i) if (s := look(ch, t)) is not None), reverse=True)
            if sims and sims[0][0] >= LOOK_MIN and \
                    (len(sims) == 1 or sims[0][0] - sims[1][0] >= LOOK_MARGIN):
                offers.append((sims[0][0], i, sims[0][1]))
        for sim, i, team in sorted(offers, reverse=True):
            if i not in owner and not any(clash(i, j) for j in taken[team]):
                give(i, team, "look")

    for i in range(len(chains)):
        if i not in owner and len(f := free(i)) == 1:
            give(i, f[0], "left")
    return owner, how


def identify(tracklets, lineup, look=None):
    """Joins tracklets and assigns teams: (chains, owner, how), as in assign_teams."""
    chains = stitch(tracklets)
    owner, how = assign_teams(chains, lineup, look)
    return chains, owner, how


def sure_chains(chains, owner, how, lineup=None, min_score=1.0, dominance=2.0, min_left_s=20.0):
    """[(team, chain)] identified beyond reasonable doubt. Only these teach the appearance
    gallery, so one bad read doesn't spread to other matches.

    - By number: enough read score, well ahead of any other team's.
    - By elimination, with lineup: a long chain on the field at the same time as sure chains
      of both other teams on its alliance, so it can only be the third robot. This is how
      teams whose numbers never read (small or blurry bumpers) get looks at all.
    """
    def span(ch):
        return min(k.start for k in ch), max(k.end for k in ch)

    out = {}
    for i, team in owner.items():
        if how[i] != "number":
            continue
        votes = _votes(chains[i]).most_common()
        top = dict(votes).get(team, 0)
        rest = max((s for t, s in votes if t != team), default=0)
        if top >= min_score and top >= dominance * rest:
            out[i] = team
    if lineup:
        for i, team in owner.items():
            a, b = span(chains[i])
            if how[i] != "left" or b - a < min_left_s:
                continue
            others = [t for t in lineup.get(chains[i][0].color, []) if t != team]
            if others and all(any(t == out.get(j) and span(chains[j])[0] < b - 0.5 and a < span(chains[j])[1] - 0.5
                                  for j in out) for t in others):
                out[i] = team
    return [(team, chains[i]) for i, team in out.items()]


def team_tracks(tracklets, lineup, look=None):
    """{team: (times, xy)}, plus each team's share of tracked time identified by number, and
    by look."""
    chains, owner, how = identify(tracklets, lineup, look)
    pts, all_time = defaultdict(list), Counter()
    by = {"number": Counter(), "look": Counter()}
    for i, team in owner.items():
        for k in chains[i]:
            pts[team] += list(zip(k.t, k.xy))
            dur = max(k.end - k.start, 0.1)
            all_time[team] += dur
            if how[i] in by:
                by[how[i]][team] += dur
    tracks = {}
    for team, p in pts.items():
        p.sort(key=lambda x: x[0])
        tracks[team] = (np.array([x[0] for x in p]), np.array([x[1] for x in p], dtype=float))
    return (tracks, {t: by["number"][t] / all_time[t] for t in all_time},
            {t: by["look"][t] / all_time[t] for t in all_time})


# ── Per-robot numbers ─────────────────────────────────────────────
def per_second(times, xy, length):
    """Median position in each covered match second: {second: (x, y)}."""
    bins = defaultdict(list)
    for t, p in zip(times, xy):
        if 0 <= t <= length:
            bins[int(t)].append(p)
    return {s: tuple(np.median(np.array(v), axis=0)) for s, v in bins.items()}


def zone_of(x, color, g):
    """'own', 'neutral' or 'opp' for a field x position."""
    L, D = g["field"]["length_in"], g["field"]["alliance_zone_depth_in"]
    if x <= D:
        return "own" if color == "red" else "opp"
    if x >= L - D:
        return "own" if color == "blue" else "opp"
    return "neutral"


def robot_metrics(times, xy, color, g):
    tm, mo = g["timing"], g["motion"]
    auto_s, length = tm["auto_s"], tm["auto_s"] + tm["teleop_s"]
    endgame_from = length - tm["endgame_s"]
    secs = per_second(times, xy, length)
    out = {"visible_share": round(len(secs) / (length + 1), 3)}

    # Distance, from second to second, skipping gaps and impossible jumps (bad detections)
    dist = auto_dist = 0.0
    keys = sorted(secs)
    for a, b in zip(keys, keys[1:]):
        if b - a > 1:
            continue
        d = float(np.hypot(secs[b][0] - secs[a][0], secs[b][1] - secs[a][1]))
        if d > mo["max_speed_in_s"]:
            continue
        dist += d
        if b <= auto_s:
            auto_dist += d
    out["distance_ft"] = round(dist / 12, 1)
    out["auto_distance_ft"] = round(auto_dist / 12, 1)

    # Left the starting zone: past its own alliance-zone line during auto
    D, L, m = g["field"]["alliance_zone_depth_in"], g["field"]["length_in"], mo["start_line_margin_in"]
    auto_x = [secs[s][0] for s in keys if s <= auto_s]
    if auto_x:
        out["auto_left_zone"] = bool(max(auto_x) > D + m) if color == "red" else bool(min(auto_x) < L - D - m)

    zones = Counter(zone_of(secs[s][0], color, g) for s in keys)
    out["own_zone_s"], out["neutral_zone_s"], out["opp_zone_s"] = zones["own"], zones["neutral"], zones["opp"]

    # Stopped: moved less than still_in_per_s from one second to the next, in teleop before endgame
    still = longest = run = 0
    for s in range(auto_s + 1, endgame_from):
        if s in secs and s - 1 in secs and \
                np.hypot(secs[s][0] - secs[s - 1][0], secs[s][1] - secs[s - 1][1]) < mo["still_in_per_s"]:
            still += 1
            run += 1
            longest = max(longest, run)
        else:
            run = 0
    out["still_s"], out["longest_still_s"] = still, longest
    return out


def contacts(secs_by_team, color_of, contact_in):
    """Close contacts with an opponent: separate episodes, at least 2 s apart, per team."""
    out = Counter()
    teams = list(secs_by_team)
    for a in teams:
        last = -10
        for s in sorted(secs_by_team[a]):
            pa = secs_by_team[a][s]
            near = any(color_of[b] != color_of[a] and s in secs_by_team[b] and
                       np.hypot(pa[0] - secs_by_team[b][s][0], pa[1] - secs_by_team[b][s][1]) < contact_in
                       for b in teams)
            if near:
                if s - last >= 2:
                    out[a] += 1
                last = s
    return out


# ── FUEL credit ───────────────────────────────────────────────────
def official_fuel(score, breakdown, g):
    """Official FUEL points for an alliance: score minus TOWER points minus foul points.

    None when the breakdown doesn't have the per-robot TOWER results.
    """
    if score is None or not breakdown:
        return None
    k, tp = g["breakdown_keys"], g["tower_points"]
    tower = 0
    for i in (1, 2, 3):
        a, e = breakdown.get(f"{k['auto_tower']}{i}"), breakdown.get(f"{k['end_tower']}{i}")
        if a is None or e is None:
            return None
        tower += tp["auto"].get(a, 0) + tp["end"].get(e, 0)
    fouls = breakdown.get(k["fouls"])
    return score - tower - (fouls if isinstance(fouls, (int, float)) else 0)


def attribute_fuel(timeline, color, secs_by_team, teams, g, total=None):
    """Credits each rise in the alliance's score to the robots likely to have scored it.

    For every second the score goes up, each robot on the alliance gets a weight from where
    it was a moment before: in its own alliance zone counts most, elsewhere a little, and not
    in view an in-between amount. Points split by weight. The windows where TOWER points land
    (end of auto, end of match) are skipped. With total (official FUEL points), credit is
    scaled to it, so only the split comes from video. Returns {team: (share, fuel_est)}.
    """
    a = g["attribution"]
    col = 1 if color == "red" else 2
    lo, hi = a["lookback_s"]
    credit = Counter()
    for prev, row in zip(timeline, timeline[1:]):
        t, rise = row[0], row[col] - prev[col]
        if rise <= 0 or any(w0 <= t <= w1 for w0, w1 in a["skip_windows_s"]):
            continue
        weights = {}
        for team in teams:
            seen = [secs_by_team.get(team, {}).get(s) for s in range(t - hi, t - lo + 1)]
            seen = [p for p in seen if p is not None]
            if not seen:
                weights[team] = a["unseen_weight"]
            else:
                own = sum(zone_of(p[0], color, g) == "own" for p in seen) / len(seen)
                weights[team] = own * a["own_zone_weight"] + (1 - own) * a["other_zone_weight"]
        total_w = sum(weights.values()) or 1
        for team, w in weights.items():
            credit[team] += rise * w / total_w
    credited = sum(credit.values())
    out = {}
    for team in teams:
        share = credit[team] / credited if credited else 0.0
        est = share * total if total is not None else credit[team]
        out[team] = (round(share, 3), round(max(est, 0), 1))
    return out


def confidence(visible_share, id_share, look_share=0.0):
    """0-1: how much of the match the robot was tracked, discounted by up to half when it
    wasn't identified. Identifying by look counts for less than by number."""
    known = min(1.0, id_share + 0.6 * look_share)
    return round(float(np.clip(visible_share * (0.5 + 0.5 * known), 0, 1)), 3)
