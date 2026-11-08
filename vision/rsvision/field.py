"""Calibration: where the scoreboard is, and how the stream's wide shot maps onto the field.

Each event has its own calibration, made once from one frame of the main wide shot and saved
under work/calib/. The field mapping is a homography for the floor, so only floor-level
landmarks (corners and tape lines) work; anything raised, like the HUB, would skew it.

During a match the broadcast cuts to close-ups and replays. Every frame is matched against
the saved wide-shot frame with ORB features; frames that don't match are skipped.
"""
import json
from pathlib import Path

import numpy as np

from . import config

OVERLAY_BOXES = ["red_score", "blue_score", "clock"]


def calib_path(event_key):
    return config.WORK / "calib" / f"{event_key}.json"


def load(event_key):
    path = calib_path(event_key)
    if not path.exists():
        raise SystemExit(f"No calibration for {event_key}. Run: python run.py calibrate --event {event_key} --video <file>")
    c = json.loads(path.read_text(encoding="utf-8"))
    c["H"] = np.array(c["H"], dtype=float)
    return c


class WideShot:
    """Checks whether a frame is the calibrated wide shot and maps it onto the field."""

    def __init__(self, calib, min_inliers=40, work_width=960):
        import cv2
        self.cv2 = cv2
        ref = cv2.imread(str(Path(calib["reference"])))
        if ref is None:
            raise SystemExit(f"Missing reference frame {calib['reference']}. Run calibrate again.")
        self.size = (ref.shape[1], ref.shape[0])
        self.scale = work_width / ref.shape[1]
        self.orb = cv2.ORB_create(nfeatures=1500)
        self.matcher = cv2.BFMatcher(cv2.NORM_HAMMING)
        self.mask = self._mask(calib, ref.shape)
        self.ref_kp, self.ref_desc = self.orb.detectAndCompute(self._small(ref), self.mask)
        self.H_field = calib["H"]       # reference image -> field inches
        self.min_inliers = min_inliers

    def _small(self, img):
        cv2 = self.cv2
        img = cv2.resize(img, self.size) if (img.shape[1], img.shape[0]) != self.size else img
        return cv2.cvtColor(cv2.resize(img, None, fx=self.scale, fy=self.scale), cv2.COLOR_BGR2GRAY)

    def _mask(self, calib, shape):
        # Leave out the scoreboard overlay: it's identical in every shot, so it would match anything
        h, w = int(shape[0] * self.scale), int(shape[1] * self.scale)
        m = np.full((h, w), 255, np.uint8)
        for name in OVERLAY_BOXES:
            x, y, bw, bh = calib["overlay"][name]
            pad = 0.02
            m[max(0, int((y - pad) * h)):int((y + bh + pad) * h), max(0, int((x - pad) * w)):int((x + bw + pad) * w)] = 0
        if calib.get("overlay_band"):
            top = int(calib["overlay_band"] * h)
            m[top:, :] = 0
        return m

    def to_field(self, frame):
        """The frame -> field homography (in full-frame pixels), or None if this isn't the wide shot."""
        cv2 = self.cv2
        kp, desc = self.orb.detectAndCompute(self._small(frame), self.mask)
        if desc is None or self.ref_desc is None or len(kp) < self.min_inliers:
            return None
        pairs = self.matcher.knnMatch(desc, self.ref_desc, k=2)
        good = [m for m, *rest in pairs if rest and m.distance < 0.75 * rest[0].distance]
        if len(good) < self.min_inliers:
            return None
        src = np.float32([kp[m.queryIdx].pt for m in good])
        dst = np.float32([self.ref_kp[m.trainIdx].pt for m in good])
        H_small, inl = cv2.findHomography(src, dst, cv2.RANSAC, 4.0)
        if H_small is None or int(inl.sum()) < self.min_inliers:
            return None
        # Back to full-size pixels: frame (resized to the reference size) -> reference
        S = np.diag([self.scale, self.scale, 1.0])
        fx, fy = self.size[0] / frame.shape[1], self.size[1] / frame.shape[0]
        R = np.diag([fx, fy, 1.0])
        H_ref = np.linalg.inv(S) @ H_small @ S @ R
        return self.H_field @ H_ref


def project(H, pts):
    """Pixel points [(x, y), ...] -> field inches through homography H."""
    p = np.hstack([np.asarray(pts, dtype=float), np.ones((len(pts), 1))]) @ H.T
    return p[:, :2] / p[:, 2:3]


def calibrate(event_key, video_path, at_s, g):
    """Interactive: draw the three scoreboard boxes, then click the field landmarks."""
    import cv2
    from .video import frame_at
    frame = frame_at(video_path, at_s)
    h, w = frame.shape[:2]
    view = frame.copy()

    overlay = {}
    for name in OVERLAY_BOXES:
        title = f"Draw a box around the {name.replace('_', ' ')}, then press Enter"
        x, y, bw, bh = cv2.selectROI(title, view, showCrosshair=False)
        cv2.destroyWindow(title)
        if bw == 0 or bh == 0:
            raise SystemExit("Calibration cancelled.")
        overlay[name] = [x / w, y / h, bw / w, bh / h]
        cv2.rectangle(view, (x, y), (x + bw, y + bh), (0, 255, 255), 2)

    print("Click each landmark on the floor. Press s to skip one you can't see, q when done (4 or more).")
    img_pts, field_pts = [], []
    for lm in g["landmarks"]:
        clicked = []
        title = f"Click: {lm['name']}  (s = skip, q = done)"

        def on_click(event, x, y, *_):
            if event == cv2.EVENT_LBUTTONDOWN:
                clicked.append((x, y))

        cv2.imshow(title, view)
        cv2.setMouseCallback(title, on_click)
        key = None
        while not clicked and key not in (ord("s"), ord("q")):
            key = cv2.waitKey(30) & 0xFF
        cv2.destroyWindow(title)
        if clicked:
            img_pts.append(clicked[0])
            field_pts.append((lm["x"], lm["y"]))
            cv2.circle(view, clicked[0], 6, (0, 255, 0), -1)
        if key == ord("q"):
            break
    if len(img_pts) < 4:
        raise SystemExit("Need at least 4 landmarks for the field mapping.")
    H, _ = cv2.findHomography(np.float32(img_pts), np.float32(field_pts), 0)

    # Check: draw the field outline and zone lines back onto the frame
    L, W, D = g["field"]["length_in"], g["field"]["width_in"], g["field"]["alliance_zone_depth_in"]
    Hinv = np.linalg.inv(H)
    for line in ([(0, 0), (L, 0), (L, W), (0, W), (0, 0)], [(D, 0), (D, W)], [(L - D, 0), (L - D, W)], [(L / 2, 0), (L / 2, W)]):
        pts = project(Hinv, line).astype(np.int32)
        cv2.polylines(view, [pts], False, (255, 0, 255), 2)
    title = "Check the magenta outline matches the field. y = save, any other key = cancel"
    cv2.imshow(title, view)
    ok = (cv2.waitKey(0) & 0xFF) == ord("y")
    cv2.destroyAllWindows()
    if not ok:
        raise SystemExit("Not saved. Run calibrate again.")

    out = calib_path(event_key)
    out.parent.mkdir(parents=True, exist_ok=True)
    ref = out.with_suffix(".png")
    cv2.imwrite(str(ref), frame)
    out.write_text(json.dumps({"event": event_key, "reference": str(ref), "overlay": overlay,
                               "H": H.tolist(), "image_points": img_pts, "field_points": field_pts}, indent=2),
                   encoding="utf-8")
    print(f"Saved {out}")
