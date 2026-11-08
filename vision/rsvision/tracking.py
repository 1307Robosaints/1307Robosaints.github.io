"""Finding and following robots: a YOLO bumper detector with ByteTrack, from ultralytics.

The model is trained on our own labeled frames (see README, "Training the bumper model").
Its classes must include "red" or "blue" in their names (red_bumper, blue_bumper) so each
detection carries its alliance color. Bumpers carry over from season to season, so the
model mostly needs retraining only when new events look different.
"""
from .metrics import Tracklet, match_number
from .ocr import read_bumper


class Tracker:
    def __init__(self, model_path, imgsz=1280, conf=0.3):
        from ultralytics import YOLO
        self.model = YOLO(str(model_path))
        self.imgsz, self.conf = imgsz, conf
        self.colors = {i: ("red" if "red" in n.lower() else "blue" if "blue" in n.lower() else None)
                       for i, n in self.model.names.items()}

    def reset(self):
        # A fresh tracker for each match, so IDs don't carry over from the last one
        predictor = getattr(self.model, "predictor", None)
        for t in getattr(predictor, "trackers", None) or []:
            t.reset()

    def detect(self, frame):
        """[(track id, color, (x1, y1, x2, y2), confidence)] for this frame."""
        r = self.model.track(frame, persist=True, tracker="bytetrack.yaml", imgsz=self.imgsz,
                             conf=self.conf, verbose=False)[0]
        if r.boxes is None or r.boxes.id is None:
            return []
        out = []
        for box, tid, cls, conf in zip(r.boxes.xyxy.tolist(), r.boxes.id.int().tolist(),
                                       r.boxes.cls.int().tolist(), r.boxes.conf.tolist()):
            color = self.colors.get(cls)
            if color:
                out.append((tid, color, tuple(box), conf))
        return out


class Observer:
    """Collects tracklets for one match: field positions plus bumper-number votes."""

    def __init__(self, lineup, field_bounds, ocr_every_s=1.0):
        self.lineup = lineup
        self.tracklets = {}
        self.last_ocr = {}
        self.ocr_every_s = ocr_every_s
        self.L, self.W = field_bounds

    def add(self, t_match, frame, detections, H, project):
        for tid, color, box, conf in detections:
            # The bottom middle of the bumper box sits on the floor, which is what H maps
            x1, y1, x2, y2 = box
            fx, fy = project(H, [((x1 + x2) / 2, y2)])[0]
            if not (-24 <= fx <= self.L + 24 and -24 <= fy <= self.W + 24):
                continue   # off the field: a robot in the queue, a cart, or a bad detection
            key = (tid, color)   # a track that flips color is treated as two
            k = self.tracklets.get(key)
            if k is None:
                k = self.tracklets[key] = Tracklet(len(self.tracklets), color)
            k.t.append(t_match)
            k.xy.append((float(fx), float(fy)))
            if t_match - self.last_ocr.get(tid, -99) >= self.ocr_every_s:
                self.last_ocr[tid] = t_match
                text, c = read_bumper(frame, box, color)
                hit = match_number(text, self.lineup.get(color, []), c) if text else None
                if hit:
                    k.votes[hit[0]] += hit[1]

    def all(self):
        return [k for k in self.tracklets.values() if len(k.t) >= 3]
