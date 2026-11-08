"""One match, start to finish.

  1. Scoreboard pass (2 reads a second over the whole video): find the match clock and the
     score timeline, and check the final score against the official one.            [Phase 1]
  2. Robot pass (10 frames a second, match time only): on wide-shot frames, detect and track
     bumpers, map them onto the field, and read bumper numbers now and then.          [Phase 2]
  3. Work out who's who (bumper numbers, then robot looks, then elimination), the per-robot
     numbers, and the FUEL split, then save. The tracks are kept in work/tracks/, so step 3
     can be redone later (reidentify) once more robots' looks are known.

Without a trained bumper model, step 2 is skipped and only the scoreboard data is saved.
"""
import json
import pickle

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
    obs = Observer(lineup, (g["field"]["length_in"], g["field"]["width_in"]),
                   embedder=getattr(tracker, "embedder", None))
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


def tracks_path(event_key, match_key):
    return config.WORK / "tracks" / event_key / f"{match_key}.pkl"


def save_tracks(event_key, match_key, saved):
    """Everything identification needs, so it can be redone later without the video."""
    p = tracks_path(event_key, match_key)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(pickle.dumps(saved))


def load_tracks(event_key, match_key):
    """What save_tracks wrote for a match, or None. Only reads files this worker wrote."""
    p = tracks_path(event_key, match_key)
    return pickle.loads(p.read_bytes()) if p.exists() else None


def process(db, event, match_key, video_path, g, tracker=None, upload=True, debug=False, log=print,
            gallery=None):
    """Runs one match from video. With a gallery, the match's clearly read robots teach it
    their looks, and unread robots are matched against it."""
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

    if tracker is None:
        row.update(status="partial", notes="Scoreboard only: no bumper model yet.")
        if end_note:
            row["notes"] += " " + end_note
        robots = []
    else:
        tracklets, wide_share = robot_pass(video_path, clock, calib, g, lineup, tracker, log)
        row["wide_shot_share"] = round(wide_share, 3)
        saved = {"row": dict(row), "tl": tl, "lineup": lineup, "official": official,
                 "tracklets": tracklets, "end_note": end_note, "samples": samples}
        save_tracks(event["tba_event_key"], match_key, saved)
        if gallery is not None:
            gallery.learn(event["tba_event_key"], match_key, tracklets, lineup)
            gallery.save()
        row, robots = finish(saved, g, gallery, event["tba_event_key"])

    if debug:
        save_debug(event["tba_event_key"], match_key, row, robots, samples, g)
    if upload:
        db.save_match(event["id"], row, robots)
    return row, robots


def finish(saved, g, gallery, event_key):
    """The match row and robot rows from a match's saved tracks."""
    row, lineup = dict(saved["row"]), saved["lineup"]
    look = gallery.matcher(event_key) if gallery is not None else None
    robots = robot_rows(saved["tracklets"], lineup, saved["tl"], saved["official"], g, look)
    expected = len(lineup["red"]) + len(lineup["blue"])
    row["status"] = "ok" if len(robots) == expected else "partial"
    notes = [f"Identified {len(robots)} of {expected} robots."] if row["status"] == "partial" else []
    row["notes"] = " ".join(notes + ([saved["end_note"]] if saved["end_note"] else [])) or None
    return row, robots


def reidentify(db, event, match_key, g, gallery, upload=True, debug=False):
    """Redoes who's who for a match from its saved tracks, with the gallery as it is now.
    None when the match has no saved tracks (run it from video first)."""
    saved = load_tracks(event["tba_event_key"], match_key)
    if saved is None:
        return None
    row, robots = finish(saved, g, gallery, event["tba_event_key"])
    if debug:
        save_debug(event["tba_event_key"], match_key, row, robots, saved["samples"], g)
    if upload:
        db.save_match(event["id"], row, robots)
    return row, robots


def robot_rows(tracklets, lineup, tl, official, g, look=None):
    tracks, id_share, look_share = metrics.team_tracks(tracklets, lineup, look)
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
        data["look_share"] = round(look_share.get(team, 0.0), 3)
        if team in fuel:
            data["fuel_share"], data["fuel_est"] = fuel[team]
        rows.append({"team_number": team, "alliance": color_of[team], "data": data,
                     "confidence": metrics.confidence(data["visible_share"], data["id_share"],
                                                      data["look_share"])})
    return rows


def save_debug(event_key, match_key, row, robots, samples, g):
    """A JSON dump of everything, for checking a match by hand."""
    out = config.WORK / "debug" / f"{event_key}_{match_key}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"match": row, "robots": robots, "scoreboard_reads": samples}, indent=1, default=str),
                   encoding="utf-8")
