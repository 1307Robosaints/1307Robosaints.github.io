"""Fine-tuning the look model on this season's robots: python run.py train-looks.

Data: work/training-data/robots/<team>/<event>_<match>_<track>_<time>.jpg, from harvest. Each
team's crops from one match are held out for testing when it has crops from two or more.

Training: ResNet-18 from ImageNet, with a cosine classifier over the teams (features and
weights normalized, so the backbone learns directions that tell robots apart, which is what
the gallery compares). Crops are turned to random multiples of 90 degrees, blurred and
color-shifted, since a robot shows up at any heading and in any light.

Test: for each held-out track, the team picked out of three (the right one and two others),
by similarity to each team's average look in the training matches: the choice the pipeline
makes on an alliance. The new model replaces models/looks.pt only when it does better than
the one in use.
"""
import json
import random
import re
from collections import defaultdict

import numpy as np

from . import config
from .appearance import LOOKS_MODEL, backbone


def _load(folder):
    """{team: {match: {track: [paths]}}}"""
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
    for p in folder.glob("*/*.jpg"):
        m = re.match(r"(.+?_[a-z]+\d+(?:m\d+)?)_(\d+)_\d+$", p.stem)
        if m:
            data[int(p.parent.name)][m.group(1)][m.group(2)].append(p)
    return data


def _split(data, rnd):
    train, test = [], []   # train: (path, team); test: (team, [paths]) per track
    for team, matches in data.items():
        keys = sorted(matches)
        held = rnd.choice(keys) if len(keys) >= 2 else None
        for k in keys:
            for paths in matches[k].values():
                if k == held:
                    test.append((team, paths))
                else:
                    train += [(p, team) for p in paths]
    return train, test


def _embed_all(net, paths, device, torch, cv2, size=128):
    """Unit look vectors, averaged over 4 rotations, as appearance.Embedder makes them."""
    mean = torch.tensor([0.485, 0.456, 0.406], device=device).view(1, 3, 1, 1)
    std = torch.tensor([0.229, 0.224, 0.225], device=device).view(1, 3, 1, 1)
    out = []
    net.eval()
    with torch.no_grad():
        for p in paths:
            rgb = cv2.cvtColor(cv2.resize(cv2.imread(str(p)), (size, size)), cv2.COLOR_BGR2RGB)
            x = torch.from_numpy(np.stack([np.rot90(rgb, k) for k in range(4)]).astype(np.float32) / 255)
            v = net((x.permute(0, 3, 1, 2).to(device) - mean) / std).mean(0).cpu().numpy()
            out.append(v / (np.linalg.norm(v) or 1))
    return np.array(out)


def evaluate(net, train, test, device, torch, cv2, rnd, per_team=40):
    """Share of held-out tracks whose team is picked correctly out of three."""
    by_team = defaultdict(list)
    for p, t in train:
        by_team[t].append(p)
    teams = [t for t in by_team if len(by_team[t]) >= 3]
    cent = {}
    for t in teams:
        v = _embed_all(net, rnd.sample(by_team[t], min(per_team, len(by_team[t]))), device, torch, cv2).mean(0)
        cent[t] = v / np.linalg.norm(v)
    rows = []   # (best similarity, margin over the next team, picked right)
    for team, paths in test:
        if team not in cent or len(teams) < 3:
            continue
        v = _embed_all(net, paths[:20], device, torch, cv2).mean(0)
        v = v / np.linalg.norm(v)
        others = rnd.sample([t for t in teams if t != team], 2)
        sims = sorted(((float(v @ cent[t]), t) for t in [team] + others), reverse=True)
        rows.append((sims[0][0], sims[0][0] - sims[1][0], sims[0][1] == team))
    if not rows:
        return None, 0, rows
    return sum(r[2] for r in rows) / len(rows), len(rows), rows


def tune_thresholds(rows, precision=0.97, min_n=20):
    """(lowest similarity, margin) that decides the most held-out tracks while staying right at
    least `precision` of the time, or None."""
    best = None
    for mn in np.arange(0.0, 1.0, 0.02):
        for mg in np.arange(0.0, 0.5, 0.01):
            sel = [r for r in rows if r[0] >= mn and r[1] >= mg]
            if len(sel) >= min_n and sum(r[2] for r in sel) / len(sel) >= precision:
                if best is None or len(sel) > best[2]:
                    best = (round(float(mn), 2), round(float(mg), 2), len(sel))
    return best


def train_looks(epochs=15, batch=64, seed=1307, log=print):
    import cv2
    import torch
    import torch.nn.functional as F
    rnd = random.Random(seed)
    data = _load(config.WORK / "training-data" / "robots")
    train, test = _split(data, rnd)
    teams = sorted({t for _, t in train})
    log(f"{len(train)} training crops of {len(teams)} teams, {len(test)} held-out tracks")
    if len(teams) < 10 or len(test) < 10:
        raise SystemExit("Not enough harvested robot crops yet. Run python run.py harvest first.")
    device = "cuda" if torch.cuda.is_available() else "cpu"

    base = backbone().to(device)
    base_acc, n, _ = evaluate(base, train, test, device, torch, cv2, random.Random(seed))
    log(f"Look model in use: {base_acc:.0%} of {n} held-out tracks picked right out of 3")

    net = backbone().to(device)
    if LOOKS_MODEL.exists():   # start from ImageNet, not from the last fine-tune
        import torchvision
        fresh = torchvision.models.resnet18(weights=torchvision.models.ResNet18_Weights.IMAGENET1K_V1)
        fresh.fc = torch.nn.Identity()
        net.load_state_dict(fresh.state_dict())
    index = {t: i for i, t in enumerate(teams)}
    head = torch.nn.Parameter(torch.randn(len(teams), 512, device=device) * 0.01)
    opt = torch.optim.AdamW([*net.parameters(), head], lr=3e-4, weight_decay=1e-4)
    mean = torch.tensor([0.485, 0.456, 0.406], device=device).view(1, 3, 1, 1)
    std = torch.tensor([0.229, 0.224, 0.225], device=device).view(1, 3, 1, 1)

    def sample(p):
        img = cv2.resize(cv2.imread(str(p)), (128, 128))
        img = np.rot90(img, rnd.randrange(4))
        if rnd.random() < 0.3:
            img = cv2.GaussianBlur(np.ascontiguousarray(img), (5, 5), rnd.uniform(0.5, 1.5))
        img = np.clip(img.astype(np.float32) * rnd.uniform(0.75, 1.25) + rnd.uniform(-20, 20), 0, 255)
        return cv2.cvtColor(img.astype(np.uint8), cv2.COLOR_BGR2RGB)

    for ep in range(epochs):
        net.train()
        rnd.shuffle(train)
        total = 0.0
        for i in range(0, len(train) - batch + 1, batch):
            chunk = train[i:i + batch]
            x = torch.from_numpy(np.stack([sample(p) for p, _ in chunk]).astype(np.float32) / 255)
            x = (x.permute(0, 3, 1, 2).to(device) - mean) / std
            y = torch.tensor([index[t] for _, t in chunk], device=device)
            logits = F.normalize(net(x)) @ F.normalize(head).T
            # Cosine classifier with a margin: same team close together, other teams pushed off
            margin = F.one_hot(y, len(teams)) * 0.2
            loss = F.cross_entropy(16 * (logits - margin), y)
            opt.zero_grad()
            loss.backward()
            opt.step()
            total += float(loss) * len(chunk)
        log(f"  pass {ep + 1}/{epochs}: loss {total / max(len(train), 1):.3f}")

    acc, n, rows = evaluate(net, train, test, device, torch, cv2, random.Random(seed))
    log(f"Fine-tuned look model: {acc:.0%} of {n} held-out tracks picked right out of 3")
    tuned = tune_thresholds(rows)
    if acc is not None and tuned and (base_acc is None or acc > base_acc):
        LOOKS_MODEL.parent.mkdir(parents=True, exist_ok=True)
        torch.save(net.eval().cpu().state_dict(), LOOKS_MODEL)
        # Thresholds belong to the model: its similarities run on their own scale
        LOOKS_MODEL.with_suffix(".json").write_text(json.dumps(
            {"look_min": tuned[0], "look_margin": tuned[1], "held_out_decided": tuned[2], "held_out_tracks": n}))
        log(f"Look matching decides when similarity >= {tuned[0]} and margin >= {tuned[1]}: "
            f"{tuned[2]} of {n} held-out tracks, at least 97% right.")
        log(f"Saved {LOOKS_MODEL}. Run the season's events from video again so their saved looks use it.")
    else:
        log("Not better than the look model in use, so it wasn't saved.")
    return base_acc, acc
