"""Public FRC datasets from Roboflow Universe, converted to this worker's labels.

    python run.py universe <universe dataset link> [--version N]

Downloads the dataset in YOLOv8 format with the team's Roboflow API key (ROBOFLOW_API_KEY in
vision/.env) to ~/rf-raw/ (a short path: Universe filenames are long), then writes work/training-data/universe/<name>/ with:
- classes blue_bumper (0) and red_bumper (1): from the class name when it says red or blue,
  otherwise from the box's own colors (prelabel.bumper_color), dropping boxes that are neither;
- one box per robot: most public datasets box each bumper side separately, so boxes of one
  color that touch or nearly touch (a robot's front and side bumpers meet at a corner) are
  joined. A join that would make a box far bigger than its parts (two robots side by side) is
  skipped. --no-merge keeps the boxes as they are, for datasets already boxed per robot.

selftrain adds every converted dataset to the training mix. Look at a few preview images
(previews/) first: a dataset that labels differently does more harm than good.
"""
import re
from pathlib import Path

import numpy as np

from . import config
from .prelabel import bumper_color

NAMES = ["blue_bumper", "red_bumper"]


def parse_link(link):
    """(workspace, project, version or None) from a Universe link like
    https://universe.roboflow.com/ws/project/dataset/3 or ws/project/3."""
    m = re.search(r"(?:universe\.roboflow\.com/)?([\w-]+)/([\w-]+)(?:/(?:dataset|model)?/?(\d+))?", link)
    if not m:
        raise SystemExit(f"Not a Universe dataset link: {link}")
    return m.group(1), m.group(2), int(m.group(3)) if m.group(3) else None


def _boxes(label_path, w, h):
    out = []
    for line in label_path.read_text(encoding="utf-8").splitlines():
        p = line.split()
        if len(p) != 5:
            continue   # polygons and other shapes aren't used
        c, x, y, bw, bh = int(p[0]), *map(float, p[1:])
        out.append((c, [(x - bw / 2) * w, (y - bh / 2) * h, (x + bw / 2) * w, (y + bh / 2) * h]))
    return out


def merge_sides(boxes, gap=0.25, grow=3.0):
    """Joins one color's bumper-side boxes that touch into one box per robot."""
    boxes = [list(b) for b in boxes]
    merged = True
    while merged:
        merged = False
        for i in range(len(boxes)):
            for j in range(i + 1, len(boxes)):
                a, b = boxes[i], boxes[j]
                g = gap * min(a[2] - a[0], a[3] - a[1], b[2] - b[0], b[3] - b[1])
                if a[0] - g > b[2] or b[0] - g > a[2] or a[1] - g > b[3] or b[1] - g > a[3]:
                    continue
                # A robot's sides meet at a corner, one wide and one tall. Two wide (or two tall)
                # boxes in a row are two robots, unless they mostly overlap (the same side twice).
                wide_a, wide_b = a[2] - a[0] > a[3] - a[1], b[2] - b[0] > b[3] - b[1]
                ix = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
                small = min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
                if wide_a == wide_b and ix < 0.5 * small:
                    continue
                u = [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]
                area = (u[2] - u[0]) * (u[3] - u[1])
                parts = max((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
                if area > grow * parts * 2:
                    continue   # more likely two robots side by side
                boxes[i] = u
                del boxes[j]
                merged = True
                break
            if merged:
                break
    return boxes


def convert(src, dest, merge=True, previews=12):
    """Converts a downloaded YOLOv8 export at src into dest. Returns (images, boxes)."""
    import cv2
    import yaml
    names = yaml.safe_load(open(src / "data.yaml", encoding="utf-8"))["names"]
    names = list(names.values()) if isinstance(names, dict) else list(names)
    fixed = {i: ("red" if "red" in n.lower() else "blue" if "blue" in n.lower() else None) for i, n in enumerate(names)}
    (dest / "images").mkdir(parents=True, exist_ok=True)
    (dest / "labels").mkdir(parents=True, exist_ok=True)
    (dest / "previews").mkdir(parents=True, exist_ok=True)
    n_img = n_box = 0
    for split in ("train", "valid", "test"):
        for img_path in sorted((src / split / "images").glob("*")):
            lab = src / split / "labels" / (img_path.stem + ".txt")
            img = cv2.imread(str(img_path))
            if img is None or not lab.exists():
                continue
            h, w = img.shape[:2]
            by_color = {"blue": [], "red": []}
            for c, box in _boxes(lab, w, h):
                color = fixed.get(c) or bumper_color(img, box)
                if color:
                    by_color[color].append(box)
            lines = []
            for color, bs in by_color.items():
                for x1, y1, x2, y2 in (merge_sides(bs) if merge else bs):
                    lines.append(f"{NAMES.index(color + '_bumper')} {(x1 + x2) / 2 / w:.6f} {(y1 + y2) / 2 / h:.6f} "
                                 f"{(x2 - x1) / w:.6f} {(y2 - y1) / h:.6f}")
            if not lines:
                continue
            name = f"{split}_{n_img:05d}"   # short: the original names can pass Windows' path limit
            cv2.imwrite(str(dest / "images" / f"{name}.jpg"), img)
            (dest / "labels" / f"{name}.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
            if n_img < previews:
                view = img.copy()
                for line in lines:
                    c, x, y, bw, bh = map(float, line.split())
                    cv2.rectangle(view, (int((x - bw / 2) * w), int((y - bh / 2) * h)),
                                  (int((x + bw / 2) * w), int((y + bh / 2) * h)), (255, 128, 0) if c == 0 else (0, 0, 255), 2)
                cv2.imwrite(str(dest / "previews" / f"{name}.jpg"), view)
            n_img += 1
            n_box += len(lines)
    return n_img, n_box


def fetch(link, version=None, merge=True, log=print):
    from roboflow import Roboflow
    config.load_env()
    ws, proj, v = parse_link(link)
    rf = Roboflow(api_key=config.need("ROBOFLOW_API_KEY"))
    project = rf.workspace(ws).project(proj)
    version = version or v or max(int(x.version) for x in project.versions())
    # A short folder: Universe filenames run long, and Windows can't open paths over 260 characters
    raw = Path.home() / "rf-raw" / f"{proj[:16]}-{version}"
    if not (raw / "data.yaml").exists():
        log(f"Downloading {ws}/{proj} version {version}...")
        project.version(version).download("yolov8", location=str(raw))
    dest = config.WORK / "training-data" / "universe" / f"{proj}-{version}"
    n_img, n_box = convert(raw, dest, merge)
    log(f"Converted {n_img} images, {n_box} robot boxes to {dest}. Check {dest / 'previews'} before selftrain.")
