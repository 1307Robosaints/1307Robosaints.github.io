"""python run.py auto <YouTube link>: from a link to finished results on the website.

1. Which event: a livestream is matched to the event whose TBA webcasts list it; a single
   match video to the TBA match that lists it. Only events from a few days around the video's
   date are checked. --event skips this.
2. Video: every played match is cut from the livestream, or the one match is downloaded.
3. Calibration: an existing one for the event is used. Otherwise one from an earlier event at
   the same venue is carried over, or one is found automatically (autocal). Either way a person
   checks the result (the check image), and can click the landmarks by hand if it's wrong.
4. Every match is processed and uploaded, then who's who is redone with all robot looks.

With --watch, it keeps going during an event: every few minutes it fetches newly posted match
videos from TBA and processes them.
"""
import json
import re
import time
from datetime import date, datetime, timedelta, timezone

from . import config


def youtube_id(link):
    """The 11-character video id from any YouTube link form, or the id itself."""
    m = re.search(r"(?:v=|youtu\.be/|/live/|/shorts/|/embed/)([\w-]{11})", link)
    if m:
        return m.group(1)
    if re.fullmatch(r"[\w-]{11}", link):
        return link
    raise SystemExit(f"Not a YouTube link: {link}")


def video_info(yid):
    import subprocess
    import sys
    out = subprocess.run([sys.executable, "-m", "yt_dlp", "-j", "--no-warnings", "--no-playlist",
                          f"https://www.youtube.com/watch?v={yid}"], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def find_event(db, yid, info, api_key, days=5):
    """(event row, match key or None) for a video, from TBA. Checks events within `days` of it."""
    from .video import _tba
    ts = info.get("release_timestamp") or info.get("timestamp")
    when = datetime.fromtimestamp(ts, timezone.utc).date() if ts else \
        datetime.strptime(info["upload_date"], "%Y%m%d").date()
    lo, hi = when - timedelta(days=days), when + timedelta(days=2)
    events = [e for e in db.select("events", select="id,name,event_date,tba_event_key", tba_event_key="not.is.null")
              if e["event_date"] and lo <= date.fromisoformat(e["event_date"][:10]) <= hi]
    print(f"Checking {len(events)} events from {lo} to {hi} for video {yid}...")
    for e in events:
        try:
            ev = _tba(f"event/{e['tba_event_key']}", api_key)
        except Exception:
            continue
        if any(w.get("type") == "youtube" and w.get("channel") == yid for w in ev.get("webcasts") or []):
            return e, None
    for e in events:
        try:
            matches = _tba(f"event/{e['tba_event_key']}/matches", api_key)
        except Exception:
            continue
        for m in matches:
            if any(v.get("type") == "youtube" and v.get("key") == yid for v in m.get("videos") or []):
                return e, m["key"].split("_", 1)[1]
    raise SystemExit("No event lists this video on TBA. Pass --event <tba key> to say which one it is.")


# ── Calibration ───────────────────────────────────────────────────
def _venue(ek, api_key):
    from .video import _tba
    try:
        e = _tba(f"event/{ek}", api_key)
    except Exception:
        return None
    parts = [e.get("location_name"), e.get("address") or e.get("city")]
    return " | ".join(p for p in parts if p) or None


def _carry_over(bg, venue, g):
    """(image points, field points, source event) from an earlier calibration at this venue,
    moved onto this event's camera view by matching the two background frames, or None."""
    import cv2
    import numpy as np
    for p in sorted((config.WORK / "calib").glob("*.json")):
        old = json.loads(p.read_text(encoding="utf-8"))
        if not venue or old.get("venue") != venue:
            continue
        ref = cv2.imread(old["reference"])
        if ref is None:
            continue
        orb = cv2.ORB_create(4000)
        g1, g2 = (cv2.cvtColor(x, cv2.COLOR_BGR2GRAY) for x in (ref, bg))
        k1, d1 = orb.detectAndCompute(g1, None)
        k2, d2 = orb.detectAndCompute(g2, None)
        if d1 is None or d2 is None:
            continue
        pairs = cv2.BFMatcher(cv2.NORM_HAMMING).knnMatch(d1, d2, k=2)
        good = [m for m, *r in pairs if r and m.distance < 0.75 * r[0].distance]
        if len(good) < 40:
            continue
        M, inl = cv2.findHomography(np.float32([k1[m.queryIdx].pt for m in good]),
                                    np.float32([k2[m.trainIdx].pt for m in good]), cv2.RANSAC, 4.0)
        if M is None or inl.sum() < 40:
            continue
        pts = cv2.perspectiveTransform(np.float32(old["image_points"]).reshape(-1, 1, 2), M).reshape(-1, 2)
        return pts.tolist(), old["field_points"], old["event"]
    return None


def _ask(question):
    try:
        return input(question).strip().lower().startswith("y")
    except EOFError:
        return False


def ensure_calibration(event_key, videos, g, api_key, assume_yes=False):
    """Makes work/calib/<event>.json if it isn't there. Returns True when there is one."""
    import cv2
    import numpy as np
    from . import autocal, field
    from .video import frame_at
    if field.calib_path(event_key).exists():
        print(f"Using the existing calibration for {event_key}.")
        return True
    print("Calibrating: finding the scoreboard and the field...")
    sample = [frame_at(v, t) for v in videos[:2] for t in (90, 150)]
    overlay = autocal.find_scoreboard(sample)
    bg = autocal.background(videos[:3])
    venue = _venue(event_key, api_key)
    found, why, source = None, None, None
    if bg is not None and overlay:
        bottom = int(min(b[1] for b in overlay.values()) * bg.shape[0]) - 10
        carried = _carry_over(bg, venue, g)
        if carried:
            found, source = carried[:2], f"carried over from {carried[2]} (same venue)"
        else:
            ip, fp = autocal.find_field(bg, g, bottom=bottom)
            found, why, source = ((ip, fp), None, "found automatically") if ip else (None, fp, None)
    elif not overlay:
        why = "couldn't find the scoreboard"
    out = field.calib_path(event_key)
    out.parent.mkdir(parents=True, exist_ok=True)
    if found:
        ip, fp = found
        H, _ = cv2.findHomography(np.float32(ip), np.float32(fp), 0)
        check = out.with_name(f"{event_key}_check.jpg")
        cv2.imwrite(str(check), autocal.check_image(bg, H, overlay, g))
        print(f"Field {source}. Check image: {check}")
        print("  The magenta lines should sit on the field's outline, zone lines and center line,")
        print("  and the yellow boxes on the red score, blue score and clock.")
        ok = assume_yes
        if not assume_yes:
            title = "Check: y = looks right, any other key = calibrate by hand"
            cv2.imshow(title, cv2.resize(cv2.imread(str(check)), (1280, 720)))
            ok = (cv2.waitKey(0) & 0xFF) == ord("y")
            cv2.destroyAllWindows()
        if ok:
            ref = out.with_suffix(".png")
            cv2.imwrite(str(ref), bg)
            out.write_text(json.dumps({"event": event_key, "reference": str(ref), "overlay": overlay, "H": H.tolist(),
                                       "image_points": ip, "field_points": fp, "venue": venue,
                                       "source": source}, indent=2), encoding="utf-8")
            print(f"Saved {out}")
            return True
    else:
        print(f"Automatic calibration didn't work: {why}.")
    if assume_yes or not _ask("Calibrate by hand now? (y/n) "):
        print(f"Skipped. Later: python run.py calibrate --event {event_key} --video {videos[0]} --at 150")
        return False
    field.calibrate(event_key, videos[0], 150, g, overlay=overlay)
    if out.exists() and venue:
        c = json.loads(out.read_text(encoding="utf-8"))
        c["venue"] = venue
        out.write_text(json.dumps(c, indent=2), encoding="utf-8")
    return out.exists()


# ── The whole thing ───────────────────────────────────────────────
def run_auto(a):
    from argparse import Namespace
    from . import cli
    from .video import download, tba_youtube_ids
    db = cli._db()
    api_key = config.need("TBA_API_KEY")
    yid = youtube_id(a.link) if a.link else None
    match_key = None
    if a.event:
        event = db.event(a.event)
    else:
        if not yid:
            raise SystemExit("Give a YouTube link, or --event.")
        event, match_key = find_event(db, yid, video_info(yid), api_key)
    ek = event["tba_event_key"]
    print(f"Event: {event['name']} ({ek})" + (f", match {match_key}" if match_key else ""))
    g = config.game(cli._season(event))
    # A link that isn't one match's video is the event's livestream: matches get cut from it
    use_stream = bool(yid) and match_key is None

    while True:
        # Video
        if match_key:
            path = config.WORK / "videos" / ek / f"{match_key}.mp4"
            if not path.exists():
                print(f"Downloading {match_key}...")
                download(yid, path)
            keys = [match_key]
        else:
            keys = cli._match_keys(db, event, "all", playoffs=True)
            if use_stream:
                cli._download_from_stream(event, keys, api_key, a.before, a.after, a.cookies_from_browser)
            else:
                for k in keys:
                    if not cli._video_for(event, k, api_key):
                        print(f"{k}: no video on TBA yet")
        have = [k for k in keys if (config.WORK / "videos" / ek / f"{k}.mp4").exists()]
        if not have:
            print("No match videos to process yet.")
        elif ensure_calibration(ek, [str(config.WORK / "videos" / ek / f"{k}.mp4") for k in have], g, api_key, a.yes):
            todo = have if a.redo else [k for k in have if not (config.WORK / "tracks" / ek / f"{k}.pkl").exists()]
            if todo:
                cli.cmd_run(Namespace(event=ek, matches=",".join(todo), playoffs=True, video=None,
                                      scoreboard_only=False, no_upload=a.no_upload, debug=False))
            # Earlier matches pick up looks learned from the new ones
            try:
                cli.cmd_identify(Namespace(event=ek, matches="all", no_upload=a.no_upload, debug=False))
            except SystemExit as e:
                print(e)
        if not a.watch:
            return
        print(f"Waiting {a.watch} minutes for new match videos (Ctrl+C to stop)...")
        time.sleep(a.watch * 60)
        match_key = None   # from now on, follow the whole event
