"""Training data without hand labeling, from match video and the official line-ups.

One pass over a match video with the current bumper model, ByteTrack and bumper OCR collects:

- pseudo/: frames with YOLO labels for self-training the bumper model. A box counts when its
  track lasts at least MIN_TRACK_S (one-frame flickers are usually junk). When a track is seen
  just before and after a frame but missed in it, its box there is filled in. A frame is kept
  only when it has exactly the line-up's number of red and blue robots and no doubtful box (a
  short track scored above DOUBT_CONF), since a robot left unlabeled teaches the model it's
  background.
- robots/<team>/: crops of robots on tracks whose bumper number read clearly (enough read score,
  well ahead of any other team on the alliance). Every crop of the track gets the label, also the
  blurry ones OCR couldn't read: those are what the look model and digit reader need to learn.
- digits/<team>/: the bumper-number strips from those same tracks, for the digit reader. Only
  strips where OCR read at least half of the number are kept, which drops strips of balls and
  mechanism but keeps blurry, partly read numbers.

Needs no calibration: only the TBA line-up, to know which teams' numbers to look for.
"""
from collections import Counter, defaultdict

import numpy as np

from . import metrics, ocr

NAMES = ["blue_bumper", "red_bumper"]   # same order as the Roboflow export
MIN_TRACK_S = 2.0
DOUBT_CONF = 0.4
FILL_GAP_S = 1.5


def _yolo(cls, box, w, h):
    x1, y1, x2, y2 = box
    return f"{cls} {(x1 + x2) / 2 / w:.6f} {(y1 + y2) / 2 / h:.6f} {(x2 - x1) / w:.6f} {(y2 - y1) / h:.6f}"


def harvest_match(video, lineup, tracker, out, tag, fps=5.0, label_every_s=2.0, read_every_s=1.0):
    """Collects all three kinds of data from one match video into out/. Returns counts."""
    import cv2
    tracker.reset()
    boxes = defaultdict(list)          # track id -> [(t, color, box, conf)]
    reads = defaultdict(Counter)       # track id -> team -> read score
    crops = defaultdict(list)          # track id -> [(t, robot crop, [strips])]
    last_read = {}
    frames_kept = []                   # (t, jpeg bytes, w, h)
    next_label = 0.0
    from .video import frames
    for t, frame in frames(video, fps):
        h, w = frame.shape[:2]
        for tid, color, box, conf in tracker.detect(frame):
            boxes[tid].append((t, color, box, conf))
            if t - last_read.get(tid, -99) < read_every_s:
                continue
            last_read[tid] = t
            x1, y1, x2, y2 = (int(v) for v in box)
            crop = frame[max(0, y1):min(h, y2), max(0, x1):min(w, x2)]
            if crop.size == 0:
                continue
            text, c = ocr.read_bumper(frame, box, color)
            hit = metrics.match_number(text, lineup.get(color, []), c) if text else None
            if hit:
                reads[tid][hit[0]] += hit[1]
            px, py = (x2 - x1) * 0.15, (y2 - y1) * 0.15
            padded = frame[max(0, int(y1 - py)):int(y2 + py), max(0, int(x1 - px)):int(x2 + px)]
            strips = []
            for s in ocr.number_strips(padded, color)[:2]:
                got = ocr.reader().readtext(s, allowlist="0123456789", detail=1, rotation_info=[180])
                strips.append((s, "".join(r[1] for r in got)))
            crops[tid].append((t, cv2.resize(crop, (128, 128), interpolation=cv2.INTER_AREA), strips))
        if t >= next_label:
            next_label = t + label_every_s
            ok, jpg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
            if ok:
                frames_kept.append((t, jpg, w, h))

    out.mkdir(parents=True, exist_ok=True)
    n = Counter()

    # Pseudo-labeled frames
    span = {tid: (b[0][0], b[-1][0]) for tid, b in boxes.items()}
    (out / "pseudo" / "images").mkdir(parents=True, exist_ok=True)
    (out / "pseudo" / "labels").mkdir(parents=True, exist_ok=True)
    half = 0.5 / fps
    for t, jpg, w, h in frames_kept:
        lines, doubtful = [], False
        for tid, b in boxes.items():
            near = [x for x in b if abs(x[0] - t) <= half]
            if near:
                _, color, box, conf = near[0]
                if span[tid][1] - span[tid][0] < MIN_TRACK_S:
                    doubtful |= conf > DOUBT_CONF
                    continue
            else:
                # Missed in this frame but seen just before and after: fill the box in
                before = [x for x in b if t - FILL_GAP_S <= x[0] < t]
                after = [x for x in b if t < x[0] <= t + FILL_GAP_S]
                if not before or not after or span[tid][1] - span[tid][0] < MIN_TRACK_S:
                    continue
                (t0, color, b0, _), (t1, _, b1, _) = before[-1], after[0]
                k = (t - t0) / (t1 - t0)
                box = tuple(p + k * (q - p) for p, q in zip(b0, b1))
            lines.append(_yolo(NAMES.index(f"{color}_bumper"), box, w, h))
        # Complete frames only: the line-up says how many robots of each color are out there
        count = Counter(int(x.split()[0]) for x in lines)
        if doubtful or count[0] != len(lineup.get("blue", [])) or count[1] != len(lineup.get("red", [])):
            continue
        name = f"{tag}_{int(t * 10):05d}"
        (out / "pseudo" / "images" / f"{name}.jpg").write_bytes(jpg.tobytes())
        (out / "pseudo" / "labels" / f"{name}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        n["frames"] += 1

    # Team-labeled crops and number strips, from tracks read beyond doubt
    for tid, votes in reads.items():
        ranked = votes.most_common()
        team, top = ranked[0]
        rest = ranked[1][1] if len(ranked) > 1 else 0
        if top < 1.0 or top < 2 * rest:
            continue
        for d in ("robots", "digits"):
            (out / d / str(team)).mkdir(parents=True, exist_ok=True)
        for t, crop, strips in crops[tid]:
            cv2.imwrite(str(out / "robots" / str(team) / f"{tag}_{tid}_{int(t * 10):05d}.jpg"), crop)
            n["crops"] += 1
            for i, (s, text) in enumerate(strips):
                # Keep strips that read as at least part of the number: blurry ones in, junk out
                digits = "".join(ch for ch in text if ch.isdigit())
                if not digits or 1 - metrics._edit_distance(digits, str(team)) / max(len(digits), len(str(team))) < 0.5:
                    continue
                s = cv2.resize(s, (max(8, int(s.shape[1] * 32 / max(s.shape[0], 1))), 32), interpolation=cv2.INTER_AREA)
                cv2.imwrite(str(out / "digits" / str(team) / f"{tag}_{tid}_{int(t * 10):05d}_{i}.png"), s)
                n["strips"] += 1
        n["teams_read"] += 1
    return n
