"""A bumper-number reader trained on this season's bumpers: python run.py train-digits.

EasyOCR is a general text reader and often gives up on small, blurry, slanted bumper numbers.
This one is a small CRNN (a few conv layers, then a bidirectional LSTM, CTC loss) trained on the
number strips harvest saved, labeled with the team from tracks whose number read clearly.
Strips from the same track where OCR only got part of the number are included, so it learns
from exactly the cases EasyOCR finds hard. Upside-down strips keep their label: the model
learns to read both ways.

The reader is used only if it does better than EasyOCR on held-out matches, at the job the
pipeline needs: picking the right team out of the three on an alliance.
"""
import random
import re
from collections import defaultdict

import numpy as np

from . import config, metrics

DIGITS_MODEL = config.MODELS / "digits.pt"
H, W = 32, 128


def _net(torch):
    nn = torch.nn

    class CRNN(nn.Module):
        def __init__(self):
            super().__init__()
            def block(i, o, pool):
                return [nn.Conv2d(i, o, 3, padding=1), nn.BatchNorm2d(o), nn.ReLU(), nn.MaxPool2d(pool)]
            self.cnn = nn.Sequential(*block(1, 32, 2), *block(32, 64, 2), *block(64, 128, (2, 1)),
                                     *block(128, 128, (2, 1)), *block(128, 128, (2, 1)))   # 32x128 -> 1x32
            self.rnn = nn.LSTM(128, 96, bidirectional=True, batch_first=True)
            self.out = nn.Linear(192, 11)   # blank + 0-9

        def forward(self, x):
            f = self.cnn(x).squeeze(2).permute(0, 2, 1)   # (batch, 32 steps, 128)
            return self.out(self.rnn(f)[0])               # (batch, 32, 11)
    return CRNN()


def _prep(img):
    """Grayscale, 32 high, padded or squeezed to 128 wide, 0-1."""
    import cv2
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    w = max(8, min(W, int(g.shape[1] * H / max(g.shape[0], 1))))
    g = cv2.resize(g, (w, H), interpolation=cv2.INTER_AREA)
    out = np.full((H, W), int(np.median(g)), np.uint8)
    out[:, :w] = g
    return out.astype(np.float32) / 255


def _decode(logp):
    """Greedy CTC: (text, confidence) from (steps, 11) log-probabilities."""
    best = logp.argmax(1)
    probs = np.exp(logp.max(1))
    text, conf, prev = [], [], 0
    for k, p in zip(best, probs):
        if k != prev and k != 0:
            text.append(str(k - 1))
            conf.append(p)
        prev = k
    return "".join(text), float(np.mean(conf)) if conf else 0.0


class Reader:
    """Loaded models/digits.pt: read(strip image) -> (text, confidence)."""

    def __init__(self, path=DIGITS_MODEL):
        import torch
        self.torch = torch
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.net = _net(torch)
        self.net.load_state_dict(torch.load(path, map_location="cpu", weights_only=True))
        self.net = self.net.eval().to(self.device)

    def read(self, img):
        x = self.torch.from_numpy(_prep(img))[None, None].to(self.device)
        with self.torch.no_grad():
            logp = self.torch.log_softmax(self.net(x), -1)[0].cpu().numpy()
        return _decode(logp)


_reader = None


def reader():
    """The trained reader, or None when there isn't one."""
    global _reader
    if _reader is None and DIGITS_MODEL.exists():
        _reader = Reader()
    return _reader


def _load(folder):
    """{match: [(path, team)]}"""
    out = defaultdict(list)
    for p in folder.glob("*/*.png"):
        m = re.match(r"(.+?_[a-z]+\d+(?:m\d+)?)_\d+_\d+_\d+$", p.stem)
        if m:
            out[m.group(1)].append((p, int(p.parent.name)))
    return out


def _pick_rate(read, held, teams, rnd):
    """Share of held-out strips whose team is picked right out of three by match_number."""
    right = total = 0
    for p, team in held:
        others = rnd.sample([t for t in teams if t != team], 2)
        text, conf = read(p)
        hit = metrics.match_number(text, [team] + others, conf) if text else None
        right += bool(hit and hit[0] == team)
        total += 1
    return right / total if total else 0.0


def train_digits(epochs=40, batch=64, seed=1307, log=print):
    import cv2
    import torch
    import torch.nn.functional as F
    rnd = random.Random(seed)
    by_match = _load(config.WORK / "training-data" / "digits")
    keys = sorted(by_match)
    rnd.shuffle(keys)
    held_keys = set(keys[:max(1, len(keys) // 6)])
    train = [x for k in keys if k not in held_keys for x in by_match[k]]
    held = [x for k in held_keys for x in by_match[k]]
    teams = sorted({t for _, t in train + held})
    log(f"{len(train)} training strips, {len(held)} held out, {len(teams)} teams")
    if len(train) < 200 or len(held) < 30 or len(teams) < 3:
        raise SystemExit("Not enough harvested number strips yet. Run python run.py harvest first.")
    device = "cuda" if torch.cuda.is_available() else "cpu"
    imgs = {p: cv2.imread(str(p)) for p, _ in train + held}

    def easy(p):
        from .ocr import reader as easyocr
        got = easyocr().readtext(imgs[p], allowlist="0123456789", detail=1, rotation_info=[180])
        return ("".join(r[1] for r in got), float(np.mean([r[2] for r in got])) if got else 0.0)
    easy_rate = _pick_rate(easy, held, teams, random.Random(seed))
    log(f"EasyOCR picks the right team out of 3 for {easy_rate:.0%} of held-out strips")

    net = _net(torch).to(device)
    opt = torch.optim.AdamW(net.parameters(), lr=1e-3, weight_decay=1e-4)
    ctc = torch.nn.CTCLoss(blank=0, zero_infinity=True)

    def sample(p):
        img = imgs[p]
        if rnd.random() < 0.5:
            img = cv2.rotate(img, cv2.ROTATE_180)
        if rnd.random() < 0.4:
            img = cv2.GaussianBlur(img, (3, 3), rnd.uniform(0.3, 1.2))
        img = np.clip(img.astype(np.float32) * rnd.uniform(0.7, 1.3) + rnd.uniform(-25, 25), 0, 255).astype(np.uint8)
        return _prep(img)

    for ep in range(epochs):
        net.train()
        rnd.shuffle(train)
        total = 0.0
        for i in range(0, len(train) - batch + 1, batch):
            chunk = train[i:i + batch]
            x = torch.from_numpy(np.stack([sample(p) for p, _ in chunk]))[:, None].to(device)
            labels = [[int(c) + 1 for c in str(t)] for _, t in chunk]
            target = torch.tensor([d for lab in labels for d in lab], device=device)
            lengths = torch.tensor([len(lab) for lab in labels], device=device)
            logp = F.log_softmax(net(x), -1).permute(1, 0, 2)   # (steps, batch, 11)
            steps = torch.full((len(chunk),), logp.shape[0], dtype=torch.long, device=device)
            loss = ctc(logp, target, steps, lengths)
            opt.zero_grad()
            loss.backward()
            opt.step()
            total += float(loss) * len(chunk)
        if (ep + 1) % 10 == 0:
            log(f"  pass {ep + 1}/{epochs}: loss {total / max(len(train), 1):.3f}")

    net.eval()

    def mine(p):
        x = torch.from_numpy(_prep(imgs[p]))[None, None].to(device)
        with torch.no_grad():
            return _decode(torch.log_softmax(net(x), -1)[0].cpu().numpy())
    rate = _pick_rate(mine, held, teams, random.Random(seed))
    log(f"Trained reader picks the right team out of 3 for {rate:.0%} of held-out strips")
    if rate > easy_rate:
        DIGITS_MODEL.parent.mkdir(parents=True, exist_ok=True)
        torch.save(net.cpu().state_dict(), DIGITS_MODEL)
        log(f"Saved {DIGITS_MODEL}. The pipeline now reads bumper numbers with it first.")
    else:
        log("Not better than EasyOCR, so it wasn't saved.")
    return easy_rate, rate
