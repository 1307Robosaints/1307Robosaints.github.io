"""Telling robots apart by how they look, for tracks whose bumper number never read.

A team's robot looks the same in all of its matches at an event, so once its number has been
read clearly in some of them, its look identifies it in the rest. That settles matches where
OCR fails (small or blurry numbers, red bumpers) or where two teams on one alliance have
numbers a partial read can't tell apart (9997 and 9991).

- Embedder: turns a robot crop into a 512-number "look" vector, using an ImageNet ResNet-18
  (downloaded once, about 45 MB). Each crop is read at four rotations and averaged, so the
  robot's heading doesn't matter.
- Gallery: per season, each team's looks from tracks identified by a clear bumper number.
  Robots change between seasons, so a new season starts empty; robots also change between
  events, so looks from the same event count first.
"""
from pathlib import Path

import numpy as np

from . import config, metrics


LOOKS_MODEL = config.MODELS / "looks.pt"   # fine-tuned by `python run.py train-looks`


def model_id():
    """Which look model is in use. Looks from different models can't be compared, so the
    gallery and saved tracks are tagged with it."""
    return f"looks-{int(LOOKS_MODEL.stat().st_mtime)}" if LOOKS_MODEL.exists() else "imagenet"


def thresholds():
    """(lowest look similarity, margin) for metrics.assign_teams: tuned with the fine-tuned
    model (models/looks.json), or the ones tuned by hand for the ImageNet model."""
    import json
    side = LOOKS_MODEL.with_suffix(".json")
    if LOOKS_MODEL.exists() and side.exists():
        t = json.loads(side.read_text(encoding="utf-8"))
        return t["look_min"], t["look_margin"]
    return metrics.LOOK_MIN, metrics.LOOK_MARGIN


def backbone():
    """ResNet-18 that outputs a 512-number vector: ImageNet weights, or models/looks.pt when
    it has been fine-tuned on this season's robots."""
    import torch
    import torchvision
    net = torchvision.models.resnet18(weights=torchvision.models.ResNet18_Weights.IMAGENET1K_V1)
    net.fc = torch.nn.Identity()
    if LOOKS_MODEL.exists():
        net.load_state_dict(torch.load(LOOKS_MODEL, map_location="cpu", weights_only=True))
    return net


class Embedder:
    def __init__(self, size=128):
        import torch
        self.torch = torch
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.id = model_id()
        self.net = backbone().eval().to(self.device)
        self.size = size
        self.mean = torch.tensor([0.485, 0.456, 0.406], device=self.device).view(1, 3, 1, 1)
        self.std = torch.tensor([0.229, 0.224, 0.225], device=self.device).view(1, 3, 1, 1)

    def __call__(self, crop):
        """Unit-length look vector (float16) for one BGR robot crop, or None if it's empty."""
        import cv2
        if crop is None or crop.size == 0:
            return None
        rgb = cv2.cvtColor(cv2.resize(crop, (self.size, self.size), interpolation=cv2.INTER_AREA),
                           cv2.COLOR_BGR2RGB)
        batch = np.stack([np.rot90(rgb, k) for k in range(4)]).astype(np.float32) / 255
        x = self.torch.from_numpy(batch).permute(0, 3, 1, 2).to(self.device)
        with self.torch.no_grad():
            v = self.net((x - self.mean) / self.std).mean(0).cpu().numpy()
        return (v / (np.linalg.norm(v) or 1)).astype(np.float16)


def chain_look(chain):
    """Mean look of a joined track (unit length), or None if it never got one."""
    vs = [v for k in chain for v in k.looks]
    if not vs:
        return None
    m = np.mean(np.asarray(vs, dtype=np.float32), axis=0)
    return m / (np.linalg.norm(m) or 1)


class Gallery:
    """Each team's looks for one season, saved to work/appearance/<season>.npz."""

    def __init__(self, season, path=None, model=None):
        self.season = int(season)
        self.path = Path(path) if path else config.WORK / "appearance" / f"{self.season}.npz"
        self.model = model or model_id()
        self.entries = []   # (team, event key, match key, vector)
        if self.path.exists():
            z = np.load(self.path, allow_pickle=False)
            # Looks from another look model don't compare: start over (appearances --rebuild)
            saved = str(z["model"]) if "model" in z.files else "imagenet"
            if saved == self.model:
                self.entries = [(int(t), str(e), str(m), v) for t, e, m, v in
                                zip(z["teams"], z["events"], z["matches"], z["vecs"])]

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        e = self.entries
        np.savez_compressed(self.path, model=np.array(self.model), teams=np.array([x[0] for x in e], dtype=np.int32),
                            events=np.array([x[1] for x in e], dtype=str),
                            matches=np.array([x[2] for x in e], dtype=str),
                            vecs=np.array([x[3] for x in e], dtype=np.float16).reshape(len(e), -1))

    def reset(self):
        self.entries = []
        if self.path.exists():
            self.path.unlink()

    def learn(self, event_key, match_key, tracklets, lineup, look_model="imagenet"):
        """Replaces this match's looks with those of its tracks identified beyond doubt (see
        metrics.sure_chains). Returns how many were added. Tracks whose looks came from another
        look model teach nothing (run the match from video again)."""
        self.entries = [x for x in self.entries if not (x[1] == event_key and x[2] == match_key)]
        if look_model != self.model:
            return 0
        chains, owner, how = metrics.identify(tracklets, lineup)
        added = 0
        for team, ch in metrics.sure_chains(chains, owner, how, lineup):
            v = chain_look(ch)
            if v is not None:
                self.entries.append((team, event_key, match_key, v.astype(np.float16)))
                added += 1
        return added

    def score(self, look, team, event_key):
        """Cosine similarity of a look to the team's average look (same event first), or None
        when the team has no looks yet this season."""
        same = [x[3] for x in self.entries if x[0] == team and x[1] == event_key]
        pool = same or [x[3] for x in self.entries if x[0] == team]
        if not pool or look is None:
            return None
        c = np.mean(np.asarray(pool, dtype=np.float32), axis=0)
        return float(np.dot(look, c / (np.linalg.norm(c) or 1)))

    def matcher(self, event_key):
        """The look(chain, team) function metrics.assign_teams takes. It carries the thresholds
        that go with the look model (look.thresholds)."""
        def look(chain, team):
            return self.score(chain_look(chain), team, event_key)
        look.thresholds = thresholds()
        return look

    def summary(self):
        """{team: (looks, matches, events)}."""
        out = {}
        for t, e, m, _ in self.entries:
            n, ms, es = out.get(t, (0, set(), set()))
            out[t] = (n + 1, ms | {(e, m)}, es | {e})
        return {t: (n, len(ms), len(es)) for t, (n, ms, es) in sorted(out.items())}
