"""Command line: python run.py <command> --help for each command's options."""
import argparse
import json
import os
import re
import sys

from . import config


def _db():
    from .db import Db
    config.load_env()
    return Db(config.need("SUPABASE_URL"), config.need("SUPABASE_SERVICE_ROLE_KEY"))


def _season(event):
    return int(event["tba_event_key"][:4])


def _match_keys(db, event, which):
    """'all' = every played qualification match; otherwise a comma list like qm1,qm2,sf3m1."""
    if which != "all":
        keys = [k.strip() for k in which.split(",") if k.strip()]
        bad = [k for k in keys if not re.fullmatch(r"qm\d{1,3}|sf\d{1,2}m\d{1,2}|f1m\d{1,2}", k)]
        if bad:
            raise SystemExit(f"Not a match key: {', '.join(bad)} (use qm12, sf3m1, f1m2)")
        return keys
    official = db.official_matches(event["id"])
    played = [k for k, m in official.items() if m["comp_level"] == "qm" and m["red_score"] is not None]
    return sorted(played, key=lambda k: int(k[2:]))


def _video_for(event, key, api_key):
    from .video import download, tba_youtube_ids
    path = config.WORK / "videos" / event["tba_event_key"] / f"{key}.mp4"
    if path.exists():
        return path
    if not api_key:
        return None
    ids = tba_youtube_ids(event["tba_event_key"], key, api_key)
    if not ids:
        return None
    print(f"  downloading {key} ({ids[0]})")
    return download(ids[0], path)


def cmd_keys(a):
    """Show the score breakdown fields for one synced match, to check the names in the game file."""
    db = _db()
    event = db.event(a.event)
    m = db.official_matches(event["id"]).get(a.match)
    if not m:
        raise SystemExit(f"{a.match} hasn't synced for {a.event}.")
    print(json.dumps({"red_breakdown": m["red_breakdown"]}, indent=2))


def cmd_download(a):
    db = _db()
    event = db.event(a.event)
    api_key = config.need("TBA_API_KEY")
    for key in _match_keys(db, event, a.matches):
        path = _video_for(event, key, api_key)
        print(f"{key}: {path or 'no video on TBA yet'}")


def cmd_calibrate(a):
    from .field import calibrate
    season = int(a.event[:4])
    calibrate(a.event, a.video, a.at, config.game(season))


def cmd_frames(a):
    """Save frames for labeling bumpers (Roboflow or CVAT, YOLO format)."""
    import cv2
    from .video import frames
    out = config.WORK / "dataset" / "images" if not a.out else a.out
    os.makedirs(out, exist_ok=True)
    stem = os.path.splitext(os.path.basename(a.video))[0]
    n = 0
    for t, frame in frames(a.video, 1 / a.every):
        cv2.imwrite(os.path.join(out, f"{stem}_{int(t * 10):05d}.jpg"), frame)
        n += 1
    print(f"Saved {n} frames to {out}")


def cmd_train(a):
    from ultralytics import YOLO
    model = YOLO(a.model)
    model.train(data=a.data, epochs=a.epochs, imgsz=a.imgsz, batch=a.batch, project=str(config.WORK / "train"),
                name="bumpers", exist_ok=True)
    print("Done. Copy work/train/bumpers/weights/best.pt to vision/models/bumpers.pt to use it.")


def cmd_run(a):
    from . import pipeline
    db = _db()
    event = db.event(a.event)
    g = config.game(_season(event))
    tracker = None
    if not a.scoreboard_only:
        mp = config.model_path()
        if mp.exists():
            from .tracking import Tracker
            tracker = Tracker(mp)
        else:
            print(f"No bumper model at {mp}, so only the scoreboard is read (Phase 1).")
    keys = _match_keys(db, event, a.matches)
    if a.video and len(keys) != 1:
        raise SystemExit("--video needs exactly one match in --matches.")
    api_key = os.environ.get("TBA_API_KEY", "")
    done = failed = 0
    for key in keys:
        print(f"{key}:")
        try:
            video = a.video or _video_for(event, key, api_key)
            if not video:
                print("  no video: none on TBA yet, or TBA_API_KEY isn't set (or pass --video)")
                continue
            row, robots = pipeline.process(db, event, key, video, g, tracker, upload=not a.no_upload, debug=a.debug)
            print(f"  {row['status']}: {len(robots)} robots" + (f" - {row.get('notes')}" if row.get("notes") else ""))
            done += 1
        except KeyboardInterrupt:
            raise
        except Exception as e:   # one bad video shouldn't stop the rest
            failed += 1
            print(f"  failed: {e}")
    print(f"Finished: {done} processed, {failed} failed.")


def main(argv=None):
    p = argparse.ArgumentParser(prog="run.py", description="1307scout vision worker")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("keys", help="print a synced match's score breakdown fields")
    s.add_argument("--event", required=True, help="TBA event key, e.g. 2026nhgrs")
    s.add_argument("--match", default="qm1")
    s.set_defaults(fn=cmd_keys)

    s = sub.add_parser("download", help="download match videos listed on TBA")
    s.add_argument("--event", required=True)
    s.add_argument("--matches", default="all")
    s.set_defaults(fn=cmd_download)

    s = sub.add_parser("calibrate", help="mark the scoreboard and field landmarks for an event")
    s.add_argument("--event", required=True)
    s.add_argument("--video", required=True)
    s.add_argument("--at", type=float, default=60, help="seconds into the video for a clear wide shot")
    s.set_defaults(fn=cmd_calibrate)

    s = sub.add_parser("frames", help="save frames from a video for labeling")
    s.add_argument("--video", required=True)
    s.add_argument("--every", type=float, default=2.0, help="seconds between frames")
    s.add_argument("--out")
    s.set_defaults(fn=cmd_frames)

    s = sub.add_parser("train", help="train the bumper detector")
    s.add_argument("--data", required=True, help="data.yaml from the labeling export")
    s.add_argument("--model", default="yolo11s.pt")
    s.add_argument("--epochs", type=int, default=100)
    s.add_argument("--imgsz", type=int, default=1280)
    s.add_argument("--batch", type=int, default=6, help="6 fits the 8 GB laptop RTX 4070 at 1280")
    s.set_defaults(fn=cmd_train)

    s = sub.add_parser("run", help="process matches and save the results")
    s.add_argument("--event", required=True)
    s.add_argument("--matches", default="all")
    s.add_argument("--video", help="a local video for a single match")
    s.add_argument("--scoreboard-only", action="store_true", help="skip robot tracking (Phase 1)")
    s.add_argument("--no-upload", action="store_true", help="don't write to Supabase")
    s.add_argument("--debug", action="store_true", help="save everything to work/debug/")
    s.set_defaults(fn=cmd_run)

    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main(sys.argv[1:])
