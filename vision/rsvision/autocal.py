"""Calibrating an event without clicks: the scoreboard boxes from OCR, the field from its lines.

Scoreboard: the FRC broadcast overlay labels the scores "BLUE" and "RED", with the score right
below each label and the clock between them. OCR on a few match frames finds those.

Field: the 2026 field has three lines that cross it wall to wall in known places:
- each alliance's HUB-and-BUMP structure, red or blue, along its alliance zone line (x = D and
  x = L - D), and
- the white center line (x = L / 2).
On a background frame (the median of many match frames, so robots and people fade out), the
two colored structures are found by color and the center line by its white tape. Their ends,
where they meet the side walls, give six floor landmarks for the homography.

Results always need a person's yes or no (the check image), since a wrong field mapping
silently ruins every position. If it fails or looks wrong, the manual calibrate is the fallback.
"""
import re

import numpy as np

from .prelabel import BLUE, RED, color_mask


# ── Background ────────────────────────────────────────────────────
def background(video_paths, per_video=12, start_s=75, end_s=225):
    """Median of frames from the middle of a few matches: robots, people and balls fade out."""
    from .video import frames
    fs = []
    for p in video_paths:
        span = max(end_s - start_s, 1)
        fs += [f for _, f in frames(p, per_video / span, start_s, end_s)][:per_video]
    if not fs:
        return None
    return np.median(np.stack(fs), axis=0).astype(np.uint8)


# ── Scoreboard ────────────────────────────────────────────────────
def find_scoreboard(frames_bgr):
    """{"red_score", "blue_score", "clock"} as normalized [x, y, w, h] boxes, voted over frames,
    or None. Looks for the "BLUE" and "RED" labels and the biggest number just below each,
    and the biggest m:ss between them."""
    from .ocr import reader
    votes = {"red_score": [], "blue_score": [], "clock": []}
    for f in frames_bgr:
        h, w = f.shape[:2]
        found = reader().readtext(f, detail=1)
        boxes = []
        for pts, text, conf in found:
            xs, ys = [p[0] for p in pts], [p[1] for p in pts]
            boxes.append((text.strip().upper(), min(xs), min(ys), max(xs), max(ys), conf))
        for c in ("blue", "red"):
            ls = [b for b in boxes if b[0] == c.upper()]
            if not ls:
                continue
            # The score sits right under its label, about twice the label's width. OCR often
            # misses a big lone digit like "0", so the box comes from the label, not the digits.
            _, lx1, ly1, lx2, ly2, _ = ls[0]
            lw, lh, lcx = lx2 - lx1, ly2 - ly1, (lx1 + lx2) / 2
            votes[f"{c}_score"].append([(lcx - 1.1 * lw) / w, (ly2 + 0.9 * lh) / h, 2.2 * lw / w, 2.4 * lh / h])
        clocks = [b for b in boxes if re.fullmatch(r"\d?\d[:.]\d\d", b[0])]
        if clocks:
            votes["clock"].append(_norm(max(clocks, key=lambda b: b[4] - b[2]), w, h))
    if not all(votes.values()):
        return None
    return {k: [float(x) for x in np.median(np.array(v), axis=0)] for k, v in votes.items()}


def _norm(b, w, h, pad=0.25):
    """A text box, padded, as a normalized [x, y, w, h]."""
    _, x1, y1, x2, y2, _ = b
    px, py = (x2 - x1) * pad, (y2 - y1) * pad
    x1, y1, x2, y2 = max(0, x1 - px), max(0, y1 - py), min(w, x2 + px), min(h, y2 + py)
    return [x1 / w, y1 / h, (x2 - x1) / w, (y2 - y1) / h]


# ── Field ─────────────────────────────────────────────────────────
def _axis(mask):
    """Principal axis of a mask's pixels: (centroid, unit direction, (lo, hi) extent along it)."""
    ys, xs = np.nonzero(mask)
    pts = np.column_stack([xs, ys]).astype(np.float64)
    c = pts.mean(0)
    _, _, vt = np.linalg.svd(pts - c, full_matrices=False)
    d = vt[0] / np.linalg.norm(vt[0])
    if d[1] < 0:
        d = -d   # point down the image: from the far wall towards the camera
    s = (pts - c) @ d
    return c, d, np.percentile(s, [1, 99])


def _structure(bg, ranges, top, bottom):
    """The alliance zone-line structure of one color: of the big blobs of that color between
    top and bottom (the field band), the long one nearest the middle of the frame. Its ends,
    (far, near) in pixels, or None."""
    import cv2
    h, w = bg.shape[:2]
    m = color_mask(bg, ranges)
    m[:top] = 0
    m[bottom:] = 0
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    n, lab, stats, cent = cv2.connectedComponentsWithStats(m)
    big = [i for i in range(1, n) if stats[i, 4] >= 0.0008 * w * h]
    best = None
    for i in big:
        if not 0.15 * w < cent[i][0] < 0.85 * w:
            continue   # the TOWERs and driver stations sit near the ends of the frame
        c, d, (lo, hi) = _axis(lab == i)
        if hi - lo < 0.06 * h:
            continue
        # The BUMP is the biggest single piece of the alliance color on the field
        if best is None or stats[i, 4] > best[0]:
            best = (stats[i, 4], i, c, d)
    if best is None:
        return None
    # The HUB and its BUMPs often come out as separate blobs: add the ones lying along its axis
    _, i0, c, d = best
    normal = np.array([-d[1], d[0]])
    parts = [i0] + [i for i in big if i != i0 and abs((cent[i] - c) @ normal) < 0.04 * w]
    c, d, (lo, hi) = _axis(np.isin(lab, parts))
    if hi - lo < 0.12 * h:
        return None   # too short to cross the field
    return c + lo * d, c + hi * d


def _center_line(bg, red, blue, top, bottom):
    """The white center line between the two structures: (far, near) ends in pixels, or None."""
    import cv2
    hsv = cv2.cvtColor(bg, cv2.COLOR_BGR2HSV)
    white = ((hsv[..., 2] > 140) & (hsv[..., 1] < 60)).astype(np.uint8) * 255
    white[:top] = 0
    white[bottom:] = 0
    # Only the band between the two structures, near the middle of it
    mid_far, mid_near = (red[0] + blue[0]) / 2, (red[1] + blue[1]) / 2
    poly = np.int32([red[0] * 0.6 + blue[0] * 0.4, blue[0] * 0.6 + red[0] * 0.4,
                     blue[1] * 0.6 + red[1] * 0.4, red[1] * 0.6 + blue[1] * 0.4])
    band = np.zeros_like(white)
    cv2.fillPoly(band, [poly], 255)
    white &= band
    segs = cv2.HoughLinesP(white, 1, np.pi / 360, 30, minLineLength=int(0.06 * bg.shape[0]), maxLineGap=30)
    if segs is None:
        return None
    want = (mid_near - mid_far) / np.linalg.norm(mid_near - mid_far)
    best = None
    for x1, y1, x2, y2 in segs[:, 0]:
        d = np.array([x2 - x1, y2 - y1], float)
        length = np.linalg.norm(d)
        if abs(d @ want) / length < 0.9:
            continue   # not running across the field
        if best is None or length > best[0]:
            best = (length, np.array([x1, y1], float), d / length)
    if best is None:
        return None
    _, p, d = best
    # Stretch it to the walls: the lines through the structures' far ends and near ends
    return _meet(p, d, red[0], blue[0]), _meet(p, d, red[1], blue[1])


def _meet(p, d, a, b):
    """Where the line through p along d crosses the line through a and b."""
    e = b - a
    A = np.array([[d[0], -e[0]], [d[1], -e[1]]])
    t, _ = np.linalg.solve(A, a - p)
    return p + t * d


def find_field(bg, g, top=None, bottom=None):
    """(image points, field points) for the six landmarks, or (None, reason)."""
    h = bg.shape[0]
    top = int(0.05 * h) if top is None else top
    bottom = int(0.95 * h) if bottom is None else bottom
    red = _structure(bg, RED, top, bottom)
    blue = _structure(bg, BLUE, top, bottom)
    if red is None or blue is None:
        return None, "couldn't find the red and blue zone-line structures"
    center = _center_line(bg, red, blue, top, bottom)
    if center is None:
        return None, "couldn't find the white center line"
    L, W, D = g["field"]["length_in"], g["field"]["width_in"], g["field"]["alliance_zone_depth_in"]
    # The far end of each line (top of the picture) is y = 0, the near end y = W. Which side
    # wall is which doesn't matter to any number the worker saves.
    img = [red[0], red[1], center[0], center[1], blue[0], blue[1]]
    fld = [(D, 0), (D, W), (L / 2, 0), (L / 2, W), (L - D, 0), (L - D, W)]
    problem = _implausible(red, center, blue, img, fld, h)
    if problem:
        return None, problem
    return [[float(x), float(y)] for x, y in img], [[float(x), float(y)] for x, y in fld]


def _implausible(red, center, blue, img, fld, h):
    """Why these lines can't be the field, or None. Low side views, where the structures
    look wider than they are long, are the usual failure."""
    import cv2
    for name, (far, near) in (("red", red), ("center", center), ("blue", blue)):
        if near[1] - far[1] < 0.1 * h:
            return f"the {name} line doesn't run from the far wall towards the camera"
    for end in (0, 1):
        xs = [red[end][0], center[end][0], blue[end][0]]
        if not (min(xs[0], xs[2]) < xs[1] < max(xs[0], xs[2])):
            return "the center line isn't between the two zone lines"
    H, _ = cv2.findHomography(np.float32(img), np.float32(fld), 0)
    from .field import project
    err = np.hypot(*(project(H, img) - np.array(fld)).T)
    if H is None or err.max() > 12:
        return f"the lines don't fit one flat field (off by up to {err.max():.0f} in)"
    return None


def check_image(frame, H, overlay, g):
    """The frame with the field outline, zone lines and center line drawn from H (magenta),
    and the scoreboard boxes (yellow), for a person to say yes or no to."""
    import cv2
    from .field import project
    view = frame.copy()
    h, w = view.shape[:2]
    L, W, D = g["field"]["length_in"], g["field"]["width_in"], g["field"]["alliance_zone_depth_in"]
    Hinv = np.linalg.inv(H)
    for line in ([(0, 0), (L, 0), (L, W), (0, W), (0, 0)], [(D, 0), (D, W)], [(L - D, 0), (L - D, W)],
                 [(L / 2, 0), (L / 2, W)]):
        dense = [(line[i][0] + (line[i + 1][0] - line[i][0]) * t, line[i][1] + (line[i + 1][1] - line[i][1]) * t)
                 for i in range(len(line) - 1) for t in np.linspace(0, 1, 20)]
        cv2.polylines(view, [project(Hinv, dense).astype(np.int32)], False, (255, 0, 255), 3)
    for name, (x, y, bw, bh) in (overlay or {}).items():
        cv2.rectangle(view, (int(x * w), int(y * h)), (int((x + bw) * w), int((y + bh) * h)), (0, 255, 255), 3)
        cv2.putText(view, name, (int(x * w), max(15, int(y * h) - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
    return view
