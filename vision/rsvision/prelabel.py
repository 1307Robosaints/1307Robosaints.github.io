"""Pre-labeling frames for the bumper model, so people fix boxes instead of drawing every one.

Two ways to find robots:
- Grounding DINO (default): a model that finds objects from a text prompt ("robot."), no
  training needed. It also boxes field structures, icons and people, so boxes too big for a
  robot are dropped, a second pass finds people to block, and what's left has to hold
  red or blue bumper fabric, which also gives its class.
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


def color_fractions(bgr):
    """{"red": share of pixels, "blue": share} that look like bumper fabric."""
    area = max(1, bgr.shape[0] * bgr.shape[1])
    return {"red": cv2.countNonZero(color_mask(bgr, RED)) / area,
            "blue": cv2.countNonZero(color_mask(bgr, BLUE)) / area}


def bumper_color(frame, box, min_frac=0.03, ratio=1.5):
    """"red" or "blue" for a robot box, or None when it holds no clear bumper color.
    Bumpers cover only the robot's edge, so a few percent of the box is plenty."""
    h, w = frame.shape[:2]
    x1, y1, x2, y2 = (int(round(v)) for v in box)
    x1, y1, x2, y2 = max(0, x1), max(0, y1), min(w, x2), min(h, y2)
    if x2 - x1 < 8 or y2 - y1 < 8:
        return None
    frac = color_fractions(frame[y1:y2, x1:x2])
    color = max(frac, key=frac.get)
    other = "blue" if color == "red" else "red"
    if frac[color] < min_frac or frac[color] < ratio * frac[other]:
        return None
    return color


def graphics_screen(frame, limit=0.35):
    """True for results and title screens: big flat red and blue panels, no field to label.
    A gameplay frame's red/blue is mostly the score bar, well under this."""
    small = cv2.resize(frame, (320, 180))
    return sum(color_fractions(small).values()) > limit


def yolo_line(cls, box, w, h):
    """One YOLO label line: class, then center and size as fractions of the image."""
    x1, y1, x2, y2 = box
    return f"{cls} {(x1 + x2) / 2 / w:.6f} {(y1 + y2) / 2 / h:.6f} {(x2 - x1) / w:.6f} {(y2 - y1) / h:.6f}"


def overlap(a, b):
    """How much of the smaller box lies inside the other (0 to 1). Catches a box around part
    of a robot that's inside the box around the whole robot, which plain IoU misses."""
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    small = min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
    return ix * iy / small if small > 0 else 0.0


class Dino:
    """Grounding DINO through Hugging Face transformers. Downloads the model on first use."""

    def __init__(self, model_id, prompt, conf, exclude="a person.", exclude_conf=0.3):
        import torch
        from transformers import AutoModelForZeroShotObjectDetection, AutoProcessor
        self.torch = torch
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.proc = AutoProcessor.from_pretrained(model_id)
        self.model = AutoModelForZeroShotObjectDetection.from_pretrained(model_id).to(self.device).eval()
        self.prompt, self.conf = prompt, conf
        self.exclude, self.exclude_conf = exclude, exclude_conf

    def _find(self, im, prompt, conf, size):
        inp = self.proc(images=im, text=prompt, return_tensors="pt").to(self.device)
        with self.torch.no_grad():
            out = self.model(**inp)
        r = self.proc.post_process_grounded_object_detection(
            out, inp.input_ids, threshold=conf, text_threshold=conf, target_sizes=[size])[0]
        return list(zip((tuple(b) for b in r["boxes"].tolist()), r["scores"].tolist()))

    def robots(self, frame):
        """[(box, conf, color)]: color is None for a robot (decided later from its pixels) and
        "skip" for a person. People get their own pass: in one prompt with robots, the model
        tends to call referees robots and miss the real ones."""
        from PIL import Image
        im = Image.fromarray(cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        out = [(b, s, None) for b, s in self._find(im, self.prompt, self.conf, frame.shape[:2])]
        if self.exclude:
            out += [(b, s, "skip") for b, s in self._find(im, self.exclude, self.exclude_conf, frame.shape[:2])]
        return out


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


def label_frame(frame, finder, max_area=0.025):
    """[(color, box, conf)] for one frame, most confident first.

    max_area: a robot in a wide shot is about 0.5-1.5% of the frame. Bigger boxes are field
    structures (the red and blue ramps pass the color check), the whole field, or close-ups.
    """
    h, w = frame.shape[:2]
    if graphics_screen(frame):
        return []
    dets, taken = [], []
    # People first, so a person the robot pass mistook for a robot is already blocked
    for box, conf, color in sorted(finder.robots(frame), key=lambda r: (r[2] != "skip", -r[1])):
        if (box[2] - box[0]) * (box[3] - box[1]) > max_area * w * h:
            continue
        if any(overlap(box, t) > 0.6 for t in taken):
            continue   # the same robot again, a part of it, or a person already found there
        if color == "skip":
            taken.append(box)
            continue
        color = color or bumper_color(frame, box)
        if color:
            taken.append(box)
            dets.append((color, box, conf))
    return dets


def run(images, finder, overwrite=False, preview=None):
    """Labels every .jpg/.png in images. Returns (labeled, no robots found, skipped, report path)."""
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
    # Outside the dataset folder, so Roboflow doesn't take it for a label file
    report = images.parent.parent / f"{images.parent.name}_no_robots.txt"
    report.write_text("\n".join(none_found) + ("\n" if none_found else ""), encoding="utf-8")
    return done, empty, skipped, report
