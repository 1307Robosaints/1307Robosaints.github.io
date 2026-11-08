"""Settings: secrets from vision/.env, folders, and the per-season game file."""
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent      # the vision/ folder
WORK = ROOT / "work"                               # videos, calibrations, debug output (not committed)
MODELS = ROOT / "models"
GAMES = Path(__file__).resolve().parent / "games"


def load_env():
    """Reads vision/.env into os.environ without overriding anything already set."""
    path = ROOT / ".env"
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def need(name):
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"{name} isn't set. Add it to vision/.env (see .env.example).")
    return value


def game(season):
    """The game file for a season, with landmark expressions (L, W, D) turned into inches."""
    path = GAMES / f"{season}.json"
    if not path.exists():
        raise SystemExit(f"No game file for {season}. Copy rsvision/games/2026.json and update it.")
    g = json.loads(path.read_text(encoding="utf-8"))
    f = g["field"]
    names = {"L": f["length_in"], "W": f["width_in"], "D": f["alliance_zone_depth_in"]}

    def value(v):
        if isinstance(v, (int, float)):
            return float(v)
        return float(eval(v, {"__builtins__": {}}, names))   # only L, W, D and arithmetic

    for lm in g["landmarks"]:
        lm["x"], lm["y"] = value(lm["x"]), value(lm["y"])
    return g


def model_path():
    return Path(os.environ.get("RS_MODEL", MODELS / "bumpers.pt"))
