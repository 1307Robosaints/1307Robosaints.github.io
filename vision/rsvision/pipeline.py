"""One match, start to finish.

  1. Scoreboard pass (2 reads a second over the whole video): find the match clock and the
     score timeline, and check the final score against the official one.            [Phase 1]
  2. Robot pass (10 frames a second, match time only): on wide-shot frames, detect and track
     bumpers, map them onto the field, and read bumper numbers now and then.          [Phase 2]
  3. Work out who's who, the per-robot numbers, and the FUEL split, then save.

Without a trained bumper model, step 2 is skipped and only the scoreboard data is saved.
"""
import json

from . import VERSION, config, field, metrics, timeline
from .ocr import Scoreboard
from .video import frames

SCOREBOARD_FPS = 2
TRACK_FPS = 10


def scoreboard_pass(video_path, calib, g, log=print):
    board = Scoreboard(calib["overlay"])
    samples = [(t, *board.read(frame)) for t, frame in frames(video_path, SCOREBOARD_FPS)]
    clock = timeline.find_clock(samples, g["timing"]["auto_s"], g["timing"]["teleop_s"])
    if clock is None:
        return samples, None, None
    log(f"  match clock: auto at {clock.auto_start:.1f}s, teleop at {clock.teleop_start:.1f}s of the video")
    return samples, clock, timeline.score_timeline(samples, clock)


def robot_pass(video_path, clock, calib, g, lineup, tracker, log=print):
    from .tracking import Observer
    wide = field.WideShot(calib)
    obs = Observer(lineup, (g["field"]["length_in"], g["field"]["width_in"]))
    tracker.reset()
    seen = total = 0
    for t, frame in frames(video_path, TRACK_FPS, start_s=max(0, clock.auto_start - 1), end_s=clock.end + 1):
        m = clock.to_match(t)
        if m is None:
            continue
        total += 1
        H = wide.to_field(frame)
        if H is None:
            continue   # a close-up, replay or cut away from the field
        seen += 1
        obs.add(m, frame, tracker.detect(frame), H, field.project)
    log(f"  wide shot in {seen} of {total} frames")
    return obs.all(), (seen / total if total else 0.0)


def process(db, event, match_key, video_path, g, tracker=None, upload=True, debug=False, log=print):
    official = db.official_matches(event["id"]).get(match_key)
    if not official:
        raise SystemExit(f"{match_key} isn't in the official data for {event['tba_event_key']}. Has the event synced?")
    calib = field.load(event["tba_event_key"])
    lineup = {"red": official["red_teams"] or [], "blue": official["blue_teams"] or []}
    row = {"match_key": match_key, "video_url": str(video_path)[:500], "status": "failed",
           "model_version": f"rsvision-{VERSION}" + (f"/{config.model_path().name}" if tracker else "/scoreboard-only")}

    samples, clock, tl = scoreboard_pass(video_path, calib, g, log)
    if clock is None or tl is None:
        row["notes"] = "Couldn't read the match clock. Check the scoreboard boxes in the calibration."
        if upload:
            db.save_match(event["id"], row, [])
        return row, []

    row.update(score_timeline=tl, final_red=tl[-1][1], final_blue=tl[-1][2])
    # foulPoints is what each alliance got from the other side's fouls
    fouls = {c: (official.get(f"{c}_breakdown") or {}).get(g["breakdown_keys"]["fouls"]) for c in ("red", "blue")}
    reached_end = timeline.reads_to_end(samples, clock)
    row["matches_official"] = timeline.agrees(row["final_red"], row["final_blue"], official["red_score"],
                                              official["blue_score"], fouls["red"], fouls["blue"]) if reached_end else None
    log(f"  scoreboard final {row['final_red']}-{row['final_blue']}, official {official['red_score']}-{official['blue_score']}"
        f" (fouls {fouls['red'] or 0}-{fouls['blue'] or 0})")
    end_note = None if reached_end else "Video ends before the match does, so the final score isn't checked."
    if end_note:
        log(f"  {end_note}")

    robots = []
    if tracker is None:
        row.update(status="partial", notes="Scoreboard only: no bumper model yet.")
    else:
        tracklets, wide_share = robot_pass(video_path, clock, calib, g, lineup, tracker, log)
        row["wide_shot_share"] = round(wide_share, 3)
        robots = robot_rows(tracklets, lineup, tl, official, g)
        found = len(robots)
        row["status"] = "ok" if found == len(lineup["red"]) + len(lineup["blue"]) else "partial"
        if row["status"] == "partial":
            row["notes"] = f"Identified {found} of {len(lineup['red']) + len(lineup['blue'])} robots."
    if end_note:
        row["notes"] = " ".join(n for n in (row.get("notes"), end_note) if n)

    if debug:
        save_debug(event["tba_event_key"], match_key, row, robots, samples, g)
    if upload:
        db.save_match(event["id"], row, robots)
    return row, robots


def robot_rows(tracklets, lineup, tl, official, g):
    tracks, id_share = metrics.team_tracks(tracklets, lineup)
    length = g["timing"]["auto_s"] + g["timing"]["teleop_s"]
    color_of = {t: c for c in ("red", "blue") for t in lineup[c]}
    secs = {t: metrics.per_second(times, xy, length) for t, (times, xy) in tracks.items()}
    touch = metrics.contacts(secs, color_of, g["motion"]["contact_in"])
    fuel = {}
    for c in ("red", "blue"):
        total = metrics.official_fuel(official[f"{c}_score"], official.get(f"{c}_breakdown"), g)
        fuel.update(metrics.attribute_fuel(tl, c, secs, lineup[c], g, total))

    rows = []
    for team, (times, xy) in tracks.items():
        data = metrics.robot_metrics(times, xy, color_of[team], g)
        data["contacts"] = touch[team]
        data["id_share"] = round(id_share.get(team, 0.0), 3)
        if team in fuel:
            data["fuel_share"], data["fuel_est"] = fuel[team]
        rows.append({"team_number": team, "alliance": color_of[team], "data": data,
                     "confidence": metrics.confidence(data["visible_share"], data["id_share"])})
    return rows


def save_debug(event_key, match_key, row, robots, samples, g):
    """A JSON dump of everything, for checking a match by hand."""
    out = config.WORK / "debug" / f"{event_key}_{match_key}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"match": row, "robots": robots, "scoreboard_reads": samples}, indent=1, default=str),
                   encoding="utf-8")
