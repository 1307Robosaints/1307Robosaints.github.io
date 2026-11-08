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


def read_bumper(frame, xyxy, pad=0.15):
    """Read a bumper's team number from its detection box. None when the box is too small."""
    x1, y1, x2, y2 = xyxy
    if y2 - y1 < 16:
        return None, 0.0
    px, py = (x2 - x1) * pad, (y2 - y1) * pad
    h, w = frame.shape[:2]
    crop = frame[max(0, int(y1 - py)):min(h, int(y2 + py)), max(0, int(x1 - px)):min(w, int(x2 + px))]
    return read_text(crop)
