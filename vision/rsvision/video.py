"""Finding and reading match video.

Match videos come from the YouTube links The Blue Alliance lists for each match, downloaded
with yt-dlp. A local file (for example a recorded stream cut to one match) works too.
Videos are for the team's own scouting only: don't republish them.
"""
import subprocess
import sys
from pathlib import Path

import requests

TBA = "https://www.thebluealliance.com/api/v3"


def tba_youtube_ids(tba_event_key, match_key, api_key):
    r = requests.get(f"{TBA}/match/{tba_event_key}_{match_key}", timeout=20,
                     headers={"X-TBA-Auth-Key": api_key, "User-Agent": "1307scout-vision"})
    if r.status_code == 404:
        return []
    r.raise_for_status()
    return [v["key"] for v in (r.json().get("videos") or []) if v.get("type") == "youtube"]


def download(youtube_id, out_path):
    """Video only, up to 1080p, as mp4. Picking a single video stream means ffmpeg isn't needed."""
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, "-m", "yt_dlp", "-q", "--no-playlist",
           "-f", "bv*[height<=1080][ext=mp4]/bv*[height<=1080]/b[height<=1080]",
           "-o", str(out_path), f"https://www.youtube.com/watch?v={youtube_id}"]
    subprocess.run(cmd, check=True)
    return out_path


# ── Cutting matches from the event livestream ─────────────────────
# Many off-season events post no per-match videos, only the day's stream. TBA lists the stream
# (event webcasts) and each match's start time, so each match can be cut out of it.

def _tba(path, api_key):
    r = requests.get(f"{TBA}/{path}", timeout=30, headers={"X-TBA-Auth-Key": api_key, "User-Agent": "1307scout-vision"})
    r.raise_for_status()
    return r.json()


def tba_stream_ids(tba_event_key, api_key):
    """YouTube ids of the event's webcasts (one per day for most events)."""
    return [w["channel"] for w in (_tba(f"event/{tba_event_key}", api_key).get("webcasts") or [])
            if w.get("type") == "youtube" and w.get("channel")]


def tba_match_times(tba_event_key, api_key):
    """{match key: Unix time the match started}, for matches that have been played."""
    return {m["key"].split("_", 1)[1]: m["actual_time"]
            for m in _tba(f"event/{tba_event_key}/matches/simple", api_key) if m.get("actual_time")}


def stream_span(youtube_id, cookies_from=None):
    """(Unix start, length in seconds) of a finished YouTube livestream. Kept in
    work/videos/streams.json once known, so retries after a bot check don't need to ask again."""
    import json
    from . import config
    cache = config.WORK / "videos" / "streams.json"
    known = json.loads(cache.read_text(encoding="utf-8")) if cache.exists() else {}
    if youtube_id in known:
        return tuple(known[youtube_id])
    cmd = [sys.executable, "-m", "yt_dlp", "-j", "--no-warnings", "--no-playlist",
           f"https://www.youtube.com/watch?v={youtube_id}"]
    if cookies_from:
        cmd[3:3] = ["--cookies-from-browser", cookies_from]
    r = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if "not a bot" in r.stderr or "Sign in" in r.stderr:
        raise BotCheck(r.stderr.strip().splitlines()[-1])
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[-300:])
    info = json.loads(r.stdout)
    start = info.get("release_timestamp") or info.get("timestamp")
    if not info.get("was_live") or not start or not info.get("duration"):
        raise RuntimeError(f"{youtube_id} isn't a finished livestream with a known start time")
    known[youtube_id] = [start, info["duration"]]
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(known, indent=1), encoding="utf-8")
    return start, info["duration"]


class BotCheck(RuntimeError):
    """YouTube wants a sign-in after many downloads in a row. It passes after a while, or with
    the browser's YouTube login (cookies_from)."""


def download_section(youtube_id, start_s, end_s, out_path, cookies_from=None):
    """Video only, up to 1080p, from start_s to end_s of the video. Cutting needs ffmpeg, which
    the imageio-ffmpeg package brings along. cookies_from: a browser name (chrome, edge,
    firefox) whose YouTube login to use, only when YouTube asks for a sign-in."""
    import imageio_ffmpeg
    out_path = Path(out_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, "-m", "yt_dlp", "-q", "--no-playlist", "--no-warnings",
           "-f", "bv*[height<=1080][ext=mp4]/bv*[height<=1080]",
           "--download-sections", f"*{max(0, start_s):.0f}-{end_s:.0f}", "--force-keyframes-at-cuts",
           "--ffmpeg-location", imageio_ffmpeg.get_ffmpeg_exe(),
           "-o", str(out_path), f"https://www.youtube.com/watch?v={youtube_id}"]
    if cookies_from:
        cmd[3:3] = ["--cookies-from-browser", cookies_from]
    r = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if r.returncode != 0:
        err = next((ln for ln in reversed(r.stderr.splitlines()) if "ERROR" in ln), r.stderr.strip()[-300:])
        if "not a bot" in err or "Sign in" in err:
            raise BotCheck(err)
        raise RuntimeError(err)
    return out_path


def frames(path, fps, start_s=0.0, end_s=None):
    """Yields (seconds into the video, BGR frame) at about fps frames per second."""
    import cv2
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise RuntimeError(f"Can't open video {path}")
    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    step = max(1, round(src_fps / fps))
    if start_s:
        cap.set(cv2.CAP_PROP_POS_MSEC, start_s * 1000)
    i = int(round(start_s * src_fps))
    try:
        while True:
            if not cap.grab():
                return
            t = i / src_fps
            if end_s is not None and t > end_s:
                return
            if i % step == 0:
                ok, frame = cap.retrieve()
                if ok:
                    yield t, frame
            i += 1
    finally:
        cap.release()


def frame_at(path, seconds):
    import cv2
    cap = cv2.VideoCapture(str(path))
    cap.set(cv2.CAP_PROP_POS_MSEC, seconds * 1000)
    ok, frame = cap.read()
    cap.release()
    if not ok:
        raise RuntimeError(f"Can't read a frame at {seconds}s from {path}")
    return frame
