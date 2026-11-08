"""Pre-labeling frames for the bumper model, so people fix boxes instead of drawing every one.

Two ways to find robots:
- Grounding DINO (default): a model that finds objects from a text prompt ("robot."), no
  training needed. It finds robots, not bumpers, and sometimes boxes logos or people, so each
  box is checked for red or blue bumper fabric, tightened to it, and dropped if there's none.
- A trained bumper model (--model, e.g. models/bumpers.pt): once a first model exists, it
  labels the next batch better. Its red/blue class names give the color.

Output is YOLO format next to the images (labels/<frame>.txt) plus data.yaml, which Roboflow
imports as annotations to review. Existing label files are kept unless --overwrite, so fixes
made by hand aren't lost.
"""
import os
from pathlib import Path

import cv2
import numpy as np

CLASSES = ["red_bumper", "blue_bumper"]

# HSV ranges for bumper fabric (OpenCV hue is 0-179). Red wraps around 0.
RED = [((0, 120, 70), (8, 255, 255)), ((170, 120, 70), (179, 255, 255))]
BLUE = [((100, 120, 50), (128, 255, 255))]


def color_mask(bgr, ranges):
    hsv = cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)
    m = np.zeros(hsv.shape[:2], np.uint8)
    for lo, hi in ranges:
        m |= cv2.inRange(hsv, np.array(lo, np.uint8), np.array(hi, np.uint8))
    # Drop specks, so a few red pixels in a logo don't count as fabric
    return cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))


def bumper_box(frame, box, min_frac=0.06):
    """(color, tightened box) for a robot box, or None when it holds no clear bumper color.

    The box only ever shrinks, to the extent of the winning color, so a red field structure
    next to the robot can't stretch it.
    """
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = (int(round(v)) for v in box)
    x1, y1, x2, y2 = max(0, x1), max(0, y1), min(w, x2), min(h, y2)
    if x2 - x1 < 8 or y2 - y1 < 8:
        return None
    crop = frame[y1:y2, x1:x2]
    area = crop.shape[0] * crop.shape[1]
    masks = {"red": color_mask(crop, RED), "blue": color_mask(crop, BLUE)}
    frac = {c: cv2.countNonZero(m) / area for c, m in masks.items()}
    color = max(frac, key=frac.get)
    other = "blue" if color == "red" else "red"
    if frac[color] < min_frac or frac[color] < 2 * frac[other]:
        return None
    ys, xs = np.nonzero(masks[color])
    # Trim the outermost 1% on each side so a stray pixel doesn't set the edge
    bx1, bx2 = np.percentile(xs, [1, 99])
    by1, by2 = np.percentile(ys, [1, 99])
    if bx2 - bx1 < 6 or by2 - by1 < 6:
        return None
    return color, (x1 + bx1, y1 + by1, x1 + bx2 + 1, y1 + by2 + 1)


def yolo_line(cls, box, w, h):
    """One YOLO label line: class, then center and size as fractions of the image."""
    x1, y1, x2, y2 = box
    return f"{cls} {(x1 + x2) / 2 / w:.6f} {(y1 + y2) / 2 / h:.6f} {(x2 - x1) / w:.6f} {(y2 - y1) / h:.6f}"


def iou(a, b):
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / union if union else 0.0


def dedupe(dets, thresh=0.5):
    """Keeps the most confident of boxes that overlap a lot: [(color, box, conf)]."""
    out = []
    for d in sorted(dets, key=lambda d: -d[2]):
        if all(iou(d[1], o[1]) < thresh for o in out):
            out.append(d)
    return out


class Dino:
    """Grounding DINO through Hugging Face transformers. Downloads the model on first use."""

    def __init__(self, model_id, prompt, conf):
        import torch
        from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor
        self.torch = torch
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.proc = AutoProcessor.from_pretrained(model_id)
        self.model = AutoModelForZeroShotObjectDetection.from_pretrained(model_id).to(self.device).eval()
        self.prompt, self.conf = prompt, conf

    def robots(self, frame):
        """[(box, conf, None)]: robot boxes without a color yet."""
        from PIL import Image
        im = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        inp = self.proc(images=im, text=self.prompt, return_tensors="pt").to(self.device)
        with self.torch.no_grad():
            out = self.model(**inp)
        r = self.proc.post_process_grounded_object_detection(
            out, inp.input_ids, threshold=self.conf, text_threshold=self.conf,
            target_sizes=[frame.shape[:2]])[0]
        return [(tuple(b), float(s), None) for b, s in zip(r["boxes"].tolist(), r["scores"].tolist())]


class Yolo:
    """A trained bumper model. Classes named with red/blue give the color directly."""

    def __init__(self, path, conf, imgsz=1280):
        from ultralytics import YOLO
        self.model = YOLO(str(path))
        self.conf, self.imgsz = conf, imgsz
        self.colors = {i: ("red" if "red" in n.lower() else "blue" if "blue" in n.lower() else None)
                       for i, n in self.model.names.items()}

    def robots(self, frame):
        r = self.model.predict(frame, conf=self.conf, imgsz=self.imgsz, verbose=False)[0]
        return [(tuple(b), float(s), self.colors.get(int(c)))
                for b, s, c in zip(r.boxes.xyxy.tolist(), r.boxes.conf.tolist(), r.boxes.cls.tolist())]


def label_frame(frame, finder, max_area=0.08):
    """[(color, box, conf)] for one frame."""
    h, w = frame.shape[:2]
    dets = []
    for box, conf, color in finder.robots(frame):
        if (box[2] - box[0]) * (box[3] - box[1]) > max_area * w * h:
            continue   # far bigger than a robot in a wide shot: the whole field, or a close-up
        if color:
            dets.append((color, box, conf))   # a trained bumper model: trust its box and color
            continue
        hit = bumper_box(frame, box)
        if hit:
            dets.append((hit[0], hit[1], conf))
    return dedupe(dets)


def run(images, finder, overwrite=False, preview=None):
    """Labels every .jpg/.png in images. Returns (labeled, no robots found, skipped) counts."""
    images = Path(images)
    labels = images.parent / "labels"
    labels.mkdir(exist_ok=True)
    if preview:
        Path(preview).mkdir(parents=True, exist_ok=True)
    (images.parent / "data.yaml").write_text(
        f"path: {images.parent.as_posix()}\ntrain: images\nval: images\n"
        f"nc: {len(CLASSES)}\nnames: {CLASSES}\n", encoding="utf-8")
    files = sorted(p for p in images.iterdir() if p.suffix.lower() in (".jpg", ".jpeg", ".png"))
    done = empty = skipped = 0
    none_found = []
    for i, p in enumerate(files, 1):
        out = labels / f"{p.stem}.txt"
        if out.exists() and not overwrite:
            skipped += 1
            continue
        frame = cv2.imread(str(p))
        if frame is None:
            continue
        h, w = frame.shape[:2]
        dets = label_frame(frame, finder)
        if not dets:
            # No file: Roboflow would read an empty one as "checked, nothing here"
            empty += 1
            none_found.append(p.name)
            continue
        out.write_text("\n".join(yolo_line(CLASSES.index(f"{c}_bumper"), b, w, h) for c, b, _ in dets) + "\n",
                       encoding="utf-8")
        done += 1
        if preview:
            for c, b, s in dets:
                bgr = (0, 0, 255) if c == "red" else (255, 128, 0)
                x1, y1, x2, y2 = (int(v) for v in b)
                cv2.rectangle(frame, (x1, y1), (x2, y2), bgr, 2)
                cv2.putText(frame, f"{s:.2f}", (x1, max(12, y1 - 4)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, bgr, 1)
            cv2.imwrite(os.path.join(preview, p.name), frame)
        if i % 25 == 0:
            print(f"  {i}/{len(files)}")
    (images.parent / "no_robots.txt").write_text("\n".join(none_found) + ("\n" if none_found else ""),
                                                 encoding="utf-8")
    return done, empty, skipped
