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
