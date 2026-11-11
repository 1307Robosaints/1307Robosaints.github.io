"""Reading digits: the scoreboard (scores, clock) and robot bumper numbers. Uses EasyOCR on the GPU."""
import numpy as np

from .timeline import parse_clock

_reader = None


def reader():
    global _reader
    if _reader is None:
        import easyocr
        _reader = easyocr.Reader(["en"], gpu=True, verbose=False)
    return _reader


def _prep(crop, height=64):
    import cv2
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    scale = height / max(gray.shape[0], 1)
    gray = cv2.resize(gray, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
    return gray


def read_text(crop, allow="0123456789"):
    """Best (text, confidence) read from a crop, or (None, 0)."""
    if crop is None or crop.size == 0:
        return None, 0.0
    results = reader().readtext(_prep(crop), allowlist=allow, detail=1, paragraph=False)
    if not results:
        return None, 0.0
    # Several pieces left to right make one string, e.g. "2" ":" "15"
    results.sort(key=lambda r: r[0][0][0])
    text = "".join(r[1] for r in results)
    return text, float(np.mean([r[2] for r in results]))


def crop_box(frame, box):
    """Crop by a normalized [x, y, w, h] box."""
    h, w = frame.shape[:2]
    x, y, bw, bh = box
    return frame[int(y * h):int((y + bh) * h), int(x * w):int((x + bw) * w)]


class Scoreboard:
    def __init__(self, overlay):
        self.overlay = overlay

    def read(self, frame):
        """(red score, blue score, clock seconds), each None when unreadable."""
        out = []
        for name in ("red_score", "blue_score"):
            text, conf = read_text(crop_box(frame, self.overlay[name]))
            out.append(int(text) if text and text.isdigit() and conf > 0.3 and len(text) <= 3 else None)
        text, conf = read_text(crop_box(frame, self.overlay["clock"]), allow="0123456789:")
        out.append(parse_clock(text) if conf > 0.3 else None)
        return tuple(out)


def number_strips(crop, color, scale=4):
    """Straightened, enlarged crops of the white digits sitting on a robot's bumper fabric.

    A detection box covers the whole robot, so its number is small, often sideways, and
    surrounded by mechanism. Reading only the white text next to bumper-colored pixels, turned
    level, works far better than reading the whole box.
    """
    import cv2
    from .prelabel import BLUE, RED, color_mask
    big = cv2.resize(crop, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
    near = cv2.dilate(color_mask(big, RED if color == "red" else BLUE), np.ones((9 * scale, 9 * scale), np.uint8))
    hsv = cv2.cvtColor(big, cv2.COLOR_BGR2HSV)
    white = ((hsv[..., 2] > 150) & (hsv[..., 1] < 90)).astype(np.uint8) * 255 & near
    # Close the gaps between digits so a number is one blob
    joined = cv2.morphologyEx(white, cv2.MORPH_CLOSE, np.ones((3 * scale, 5 * scale), np.uint8))
    n, lab, stats, _ = cv2.connectedComponentsWithStats(joined)
    strips = []
    for i in range(1, n):
        if stats[i, 4] < 30 * scale * scale or max(stats[i, 2], stats[i, 3]) < 12 * scale:
            continue
        pts = np.column_stack(np.nonzero(lab == i))[:, ::-1].astype(np.float32)
        (cx, cy), (rw, rh), ang = cv2.minAreaRect(pts)
        if rw < rh:
            rw, rh, ang = rh, rw, ang + 90
        if rw / max(rh, 1) < 1.3:
            continue   # a team number is wider than it is tall
        level = cv2.warpAffine(big, cv2.getRotationMatrix2D((cx, cy), ang, 1.0), big.shape[1::-1],
                               flags=cv2.INTER_CUBIC)
        pad = rh * 0.35
        s = level[max(0, int(cy - rh / 2 - pad)):int(cy + rh / 2 + pad),
                  max(0, int(cx - rw / 2 - pad)):int(cx + rw / 2 + pad)]
        if s.size:
            strips.append(s)
    return strips


def read_bumper(frame, xyxy, color=None, pad=0.15):
    """Best (text, confidence) read of a robot's team number from its detection box.

    Tries each bumper number strip (right way up or upside down), then the whole box enlarged.
    (None, 0) when the box is too small or nothing reads.
    """
    x1, y1, x2, y2 = xyxy
    if y2 - y1 < 16:
        return None, 0.0
    px, py = (x2 - x1) * pad, (y2 - y1) * pad
    h, w = frame.shape[:2]
    crop = frame[max(0, int(y1 - py)):min(h, int(y2 + py)), max(0, int(x1 - px)):min(w, int(x2 + px))]
    if crop.size == 0:
        return None, 0.0
    strips = number_strips(crop, color) if color else []
    best = (None, 0.0)
    from .digits import reader as trained
    if trained() and strips:
        # The reader trained on this season's bumpers (train-digits), when there is one
        for s in strips:
            text, conf = trained().read(s)
            if len(text) >= 2 and conf > best[1]:
                best = (text, conf)
    for img in strips + [_prep(crop, 256)]:
        for _, text, conf in reader().readtext(img, allowlist="0123456789", detail=1, rotation_info=[180]):
            if len(text) >= 2 and conf > best[1]:
                best = (text, float(conf))
    return best
