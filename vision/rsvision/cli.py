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
    # Event folder + match (2026nhrr_qm1), so qm1 from two events doesn't overwrite the other
    event = os.path.basename(os.path.dirname(os.path.abspath(a.video)))
    stem = f"{event}_{os.path.splitext(os.path.basename(a.video))[0]}"
    n = 0
    for t, frame in frames(a.video, 1 / a.every):
        cv2.imwrite(os.path.join(out, f"{stem}_{int(t * 10):05d}.jpg"), frame)
        n += 1
    print(f"Saved {n} frames to {out}")


def cmd_prelabel(a):
    """Draft bumper labels for the saved frames, to review in Roboflow instead of drawing them."""
    from . import prelabel
    images = a.images or config.WORK / "dataset" / "images"
    if not os.path.isdir(images):
        raise SystemExit(f"No frames at {images}. Save some with the frames command first.")
    if a.model:
        finder = prelabel.Yolo(a.model, conf=a.conf or 0.25)
    else:
        try:
            finder = prelabel.Dino(a.dino, a.prompt, conf=a.conf or 0.15)
        except ImportError:
            raise SystemExit('Grounding DINO needs transformers: pip install "transformers>=4.45,<5"')
    done, empty, skipped, report = prelabel.run(images, finder, overwrite=a.overwrite, preview=a.preview)
    print(f"Labeled {done} frames. Kept {skipped} existing label files.")
    print(f"No robots found in {empty}, listed in {report}. Most are results screens or close-ups to delete.")


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
    gallery = None
    if tracker:
        from .appearance import Gallery
        gallery = Gallery(_season(event))
    api_key = os.environ.get("TBA_API_KEY", "")
    done, failed, partial = 0, 0, []
    for key in keys:
        print(f"{key}:")
        try:
            video = a.video or _video_for(event, key, api_key)
            if not video:
                print("  no video: none on TBA yet, or TBA_API_KEY isn't set (or pass --video)")
                continue
            row, robots = pipeline.process(db, event, key, video, g, tracker, upload=not a.no_upload,
                                           debug=a.debug, gallery=gallery)
            print(f"  {row['status']}: {len(robots)} robots" + (f" - {row.get('notes')}" if row.get("notes") else ""))
            done += 1
            if tracker and row["status"] == "partial":
                partial.append((key, len(robots)))
        except KeyboardInterrupt:
            raise
        except Exception as e:   # one bad video shouldn't stop the rest
            failed += 1
            print(f"  failed: {e}")
    print(f"Finished: {done} processed, {failed} failed.")
    if partial:
        # Matches run early didn't have the looks learned from later ones yet
        print("Second pass: matching unread robots by look, now that every match has been seen.")
        _reidentify(db, event, g, gallery, partial, a.no_upload, a.debug)


def _reidentify(db, event, g, gallery, keys_found, no_upload, debug):
    """Reruns who's who for [(match key, robots found before)], saving only when it finds more."""
    from . import pipeline
    for key, before in keys_found:
        out = pipeline.reidentify(db, event, key, g, gallery, upload=False, debug=False)
        if out is None:
            print(f"{key}: no saved tracks. Run it from video first.")
            continue
        row, robots = out
        if len(robots) > before:
            pipeline.reidentify(db, event, key, g, gallery, upload=not no_upload, debug=debug)
            print(f"{key}: {before} -> {len(robots)} robots")
        else:
            print(f"{key}: still {len(robots)} robots")


def cmd_identify(a):
    """Redoes who's who from saved tracks, without the video: after more matches or events have
    taught the gallery more looks, or after a gallery rebuild."""
    from . import pipeline
    from .appearance import Gallery
    db = _db()
    event = db.event(a.event)
    g = config.game(_season(event))
    gallery = Gallery(_season(event))
    folder = config.WORK / "tracks" / event["tba_event_key"]
    keys = sorted(p.stem for p in folder.glob("*.pkl")) if a.matches == "all" else _match_keys(db, event, a.matches)
    if not keys:
        raise SystemExit(f"No saved tracks for {a.event}. Run the event from video first.")
    for key in keys:
        out = pipeline.reidentify(db, event, key, g, gallery, upload=not a.no_upload, debug=a.debug)
        if out is None:
            print(f"{key}: no saved tracks")
            continue
        row, robots = out
        how = {"number": 0, "look": 0, "left": 0}
        for r in robots:
            d = r["data"]
            how["number" if d["id_share"] > 0 else "look" if d["look_share"] > 0 else "left"] += 1
        print(f"{key}: {row['status']}, {len(robots)} robots "
              f"({how['number']} by number, {how['look']} by look, {how['left']} by elimination)")


def cmd_appearances(a):
    """Shows, clears or rebuilds a season's robot looks."""
    from . import pipeline
    from .appearance import Gallery
    gallery = Gallery(a.season)
    if a.reset or a.rebuild:
        gallery.reset()
        print(f"Cleared the {a.season} looks.")
    if a.rebuild:
        # Every saved match of the season, oldest event folder first
        n = 0
        for folder in sorted((config.WORK / "tracks").glob(f"{a.season}*")):
            for p in sorted(folder.glob("*.pkl")):
                saved = pipeline.load_tracks(folder.name, p.stem)
                n += gallery.learn(folder.name, p.stem, saved["tracklets"], saved["lineup"])
        gallery.save()
        print(f"Rebuilt from saved tracks: {n} looks.")
    s = gallery.summary()
    print(f"{a.season}: {len(s)} teams, {len(gallery.entries)} looks ({gallery.path})")
    for team, (n, matches, events) in s.items():
        print(f"  {team:>5}: {n} looks from {matches} matches at {events} event(s)")


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

    s = sub.add_parser("prelabel", help="draft bumper labels for saved frames, to review in Roboflow")
    s.add_argument("--images", help="frames folder (default work/dataset/images)")
    s.add_argument("--model", help="a trained bumper model to use instead of Grounding DINO")
    s.add_argument("--dino", default="IDEA-Research/grounding-dino-base", help="Grounding DINO model id")
    s.add_argument("--prompt", default="a robot.", help="what Grounding DINO looks for")
    s.add_argument("--conf", type=float, help="lowest confidence kept (0.15 DINO, 0.25 trained model)")
    s.add_argument("--overwrite", action="store_true", help="replace existing label files")
    s.add_argument("--preview", help="also save frames with the boxes drawn to this folder")
    s.set_defaults(fn=cmd_prelabel)

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

    s = sub.add_parser("identify", help="redo who's who from saved tracks, using robot looks (no video)")
    s.add_argument("--event", required=True)
    s.add_argument("--matches", default="all", help="'all' saved matches, or a comma list")
    s.add_argument("--no-upload", action="store_true", help="don't write to Supabase")
    s.add_argument("--debug", action="store_true", help="save everything to work/debug/")
    s.set_defaults(fn=cmd_identify)

    s = sub.add_parser("appearances", help="show, clear or rebuild a season's robot looks")
    s.add_argument("--season", type=int, required=True)
    s.add_argument("--reset", action="store_true", help="clear the season's looks")
    s.add_argument("--rebuild", action="store_true", help="clear, then relearn from every saved match")
    s.set_defaults(fn=cmd_appearances)

    a = p.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main(sys.argv[1:])
