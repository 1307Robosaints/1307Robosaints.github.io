"""Turning noisy scoreboard reads into a match clock and a clean score timeline.

Pure numpy, so it can be tested without a GPU or video (see tests/).
A sample is (seconds into the video, red score, blue score, clock seconds); any read can be None.
"""
from dataclasses import dataclass

import numpy as np


@dataclass
class MatchClock:
    """Maps video time to match time. Match time runs 0-20 in auto, then 20-160 in teleop."""
    auto_start: float     # video second the auto clock started
    teleop_start: float   # video second the teleop clock started
    auto_s: float
    teleop_s: float

    @property
    def end(self):
        return self.teleop_start + self.teleop_s

    @property
    def length(self):
        return self.auto_s + self.teleop_s

    def to_match(self, t):
        """Match seconds for video second t, or None outside the match and in the auto-teleop pause."""
        if self.auto_start <= t <= self.auto_start + self.auto_s:
            return t - self.auto_start
        if self.teleop_start <= t <= self.end:
            return self.auto_s + (t - self.teleop_start)
        return None


def _robust_center(values, tol=1.5):
    """Median of the values that sit near the median: one bad read can't move it."""
    if not values:
        return None
    v = np.asarray(values, dtype=float)
    med = np.median(v)
    near = v[np.abs(v - med) <= tol]
    return float(np.median(near)) if len(near) >= max(2, len(v) // 3) else None


def find_clock(samples, auto_s=20, teleop_s=140):
    """Works out when auto and teleop started from the countdown clock.

    In teleop the clock counts down from teleop_s, so every read above auto_s must be teleop
    and gives an estimate of when teleop started. Reads at or under auto_s before that are
    auto. Each phase's start is the robust median of its estimates.
    """
    reads = [(t, c) for t, _, _, c in samples if c is not None and 0 <= c <= teleop_s]
    tele_est = [t - (teleop_s - c) for t, c in reads if c > auto_s + 1]
    teleop_start = _robust_center(tele_est)
    if teleop_start is None:
        return None
    # Only reads just before teleop, so a static pre-match clock can't pass for auto
    auto_est = [t - (auto_s - c) for t, c in reads
                if c <= auto_s and teleop_start - auto_s - 10 < t < teleop_start - 0.5]
    auto_start = _robust_center(auto_est)
    if auto_start is None or not (0 < teleop_start - (auto_start + auto_s) < 10):
        auto_start = teleop_start - auto_s - 3   # no auto reads: assume the usual short pause
    return MatchClock(auto_start, teleop_start, auto_s, teleop_s)


def _median_filter(v, k=5):
    out = v.copy()
    h = k // 2
    for i in range(len(v)):
        w = v[max(0, i - h): i + h + 1]
        w = w[~np.isnan(w)]
        out[i] = np.median(w) if len(w) else np.nan
    return out


def _isotonic(v):
    """Closest non-decreasing sequence (pool adjacent violators). Scores only go up in a match."""
    blocks = []   # [sum, count]
    for x in v:
        blocks.append([x, 1])
        while len(blocks) > 1 and blocks[-2][0] / blocks[-2][1] > blocks[-1][0] / blocks[-1][1]:
            s, c = blocks.pop()
            blocks[-1][0] += s
            blocks[-1][1] += c
    out = []
    for s, c in blocks:
        out += [s / c] * c
    return np.array(out)


def score_timeline(samples, clock, after_s=6):
    """One [match second, red, blue] row per second, from 0 to the end of the match.

    Reads are binned per match second, a median filter removes single bad reads, and the
    result is forced to never go down. after_s seconds past the end are read too, so a
    last-second score still counts; they're folded into the final row.
    """
    n = int(clock.length) + 1
    series = {}
    for idx, color in ((1, "red"), (2, "blue")):
        bins = [[] for _ in range(n)]
        for s in samples:
            t, v = s[0], s[idx]
            if v is None:
                continue
            m = clock.to_match(t)
            if m is None and clock.end < t <= clock.end + after_s:
                m = clock.length
            if m is not None:
                bins[min(n - 1, int(m))].append(v)
        raw = np.array([np.median(b) if b else np.nan for b in bins], dtype=float)
        filt = _median_filter(raw)
        known = ~np.isnan(filt)
        if not known.any():
            return None
        # Fill gaps by carrying the last known value forward (0 before the first read)
        filled, last = np.zeros(n), 0.0
        for i in range(n):
            last = filt[i] if known[i] else last
            filled[i] = last
        series[color] = np.round(_isotonic(filled)).astype(int)
    return [[i, int(series["red"][i]), int(series["blue"][i])] for i in range(n)]


def agrees(final_red, final_blue, official_red, official_blue, tol=5):
    """True when the scoreboard's final read is within tol of the official score.

    Scores can change after a match (fouls reviewed), so an exact match isn't required.
    """
    if None in (final_red, final_blue, official_red, official_blue):
        return None
    return abs(final_red - official_red) <= tol and abs(final_blue - official_blue) <= tol


def parse_clock(text):
    """'2:15' -> 135, '0:07' -> 7, '45' -> 45. None when it doesn't look like a clock."""
    text = (text or "").strip().replace(" ", "").replace(".", ":")
    if not text:
        return None
    if ":" in text:
        m, _, s = text.partition(":")
        if not (m.isdigit() and s.isdigit() and len(s) == 2):
            return None
        return int(m) * 60 + int(s)
    return int(text) if text.isdigit() and len(text) <= 3 else None
