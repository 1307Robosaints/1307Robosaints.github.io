"""Tests for the parts that don't need video or a GPU. Run from vision/: python -m unittest"""
import random
import unittest
from collections import Counter

from rsvision import config, metrics, timeline

G = config.game(2026)
L, W, D = G["field"]["length_in"], G["field"]["width_in"], G["field"]["alliance_zone_depth_in"]


def fake_samples(auto_start=12.0, pause=3.0, red_rate=0.5, blue_rate=0.3, noise=0.1, seed=1):
    """Scoreboard reads at 2 per second, with some unreadable and some badly misread."""
    rnd = random.Random(seed)
    teleop_start = auto_start + 20 + pause
    out = []
    t = 0.0
    while t < teleop_start + 150:
        if t < auto_start:
            m, clock = None, 20
        elif t <= auto_start + 20:
            m, clock = t - auto_start, int(round(20 - (t - auto_start)))
        elif t < teleop_start:
            m, clock = 20, 140
        elif t <= teleop_start + 140:
            m, clock = 20 + t - teleop_start, int(round(140 - (t - teleop_start)))
        else:
            m, clock = 160, 0
        red = int((m or 0) * red_rate) if m is not None else 0
        blue = int((m or 0) * blue_rate) if m is not None else 0
        if rnd.random() < noise:
            red = rnd.choice([None, red + 80])
        if rnd.random() < noise:
            clock = rnd.choice([None, 99])
        out.append((t, red, blue, clock))
        t += 0.5
    return out, teleop_start


class TimelineTests(unittest.TestCase):
    def test_clock_found_despite_noise(self):
        samples, teleop_start = fake_samples()
        c = timeline.find_clock(samples)
        self.assertAlmostEqual(c.auto_start, 12.0, delta=0.6)
        self.assertAlmostEqual(c.teleop_start, teleop_start, delta=0.6)
        self.assertIsNone(c.to_match(c.auto_start + 21.5))   # the pause between auto and teleop
        self.assertAlmostEqual(c.to_match(c.teleop_start + 10), 30, delta=0.01)

    def test_scores_never_drop_and_ignore_spikes(self):
        samples, _ = fake_samples()
        c = timeline.find_clock(samples)
        tl = timeline.score_timeline(samples, c)
        self.assertEqual(len(tl), 161)
        reds = [r[1] for r in tl]
        self.assertEqual(reds, sorted(reds))
        self.assertAlmostEqual(tl[-1][1], 80, delta=3)   # 160 s x 0.5, the +80 misreads filtered out
        self.assertAlmostEqual(tl[-1][2], 48, delta=3)

    def test_no_clock(self):
        self.assertIsNone(timeline.find_clock([(t, 0, 0, None) for t in range(100)]))

    def test_parse_clock(self):
        self.assertEqual(timeline.parse_clock("2:15"), 135)
        self.assertEqual(timeline.parse_clock("0:07"), 7)
        self.assertEqual(timeline.parse_clock("45"), 45)
        self.assertIsNone(timeline.parse_clock("2:1"))
        self.assertIsNone(timeline.parse_clock(""))

    def test_agrees(self):
        self.assertTrue(timeline.agrees(100, 80, 104, 80))
        self.assertFalse(timeline.agrees(100, 80, 120, 80))
        self.assertIsNone(timeline.agrees(None, 80, 120, 80))
        # Blue got 15 foul points the overlay didn't show live
        self.assertTrue(timeline.agrees(166, 347, 166, 363, 0, 15))
        self.assertFalse(timeline.agrees(166, 347, 166, 363))

    def test_reads_to_end(self):
        clock = timeline.MatchClock(auto_start=10, teleop_start=33, auto_s=20, teleop_s=140)  # ends at 173
        cut = [(170.0, 150, 340, 3), (171.0, None, None, None)]
        self.assertFalse(timeline.reads_to_end(cut, clock))
        self.assertFalse(timeline.reads_to_end(cut + [(195.0, 85, 86, 298)], clock))  # junk after a cut
        self.assertTrue(timeline.reads_to_end(cut + [(172.5, 158, 347, 0)], clock))


def path(color, x0, x1, t0=0, t1=160, y=150.0, step=0.5):
    """A robot driving in a straight line from x0 to x1 between t0 and t1."""
    k = metrics.Tracklet(random.randint(0, 10 ** 9), color)
    t = t0
    while t <= t1:
        k.t.append(t)
        k.xy.append((x0 + (x1 - x0) * (t - t0) / max(t1 - t0, 1e-9), y))
        t += step
    return k


class IdentityTests(unittest.TestCase):
    def test_number_read_picks_closest_team(self):
        self.assertEqual(metrics.match_number("1307", [1307, 1729, 5687])[0], 1307)
        self.assertEqual(metrics.match_number("130", [1307, 1729, 5687])[0], 1307)
        self.assertIsNone(metrics.match_number("99", [1307, 1729, 5687]))
        self.assertIsNone(metrics.match_number("17", [1729, 1797, 5687]))   # too close to call

    def test_stitch_joins_a_broken_track(self):
        a = path("red", 50, 100, 0, 30)
        b = path("red", 105, 200, 31, 60)          # starts 1 s later, nearby
        c = path("red", 600, 600, 31, 60)          # starts 1 s later, far away
        chains = metrics.stitch([a, b, c])
        self.assertEqual(len(chains), 2)
        self.assertIn([a, b], chains)

    def test_votes_then_deduction(self):
        lineup = {"red": [1, 2, 3], "blue": [4, 5, 6]}
        r1, r2, r3 = path("red", 0, 300, y=50), path("red", 0, 300, y=150), path("red", 0, 300, y=250)
        r1.votes[1] += 5
        r2.votes[2] += 3
        r2.votes[1] += 1                           # a weaker, wrong read
        tracks, ids, looks = metrics.team_tracks([r1, r2, r3], lineup)
        self.assertEqual(set(tracks), {1, 2, 3})   # 3 had no reads but was the only one left
        self.assertEqual(ids[1], 1.0)
        self.assertEqual(ids[3], 0.0)
        self.assertEqual(looks[3], 0.0)
        self.assertAlmostEqual(float(tracks[3][1][0][1]), 250)

    def test_look_identifies_unread_robots(self):
        # 9997 and 9991 on one alliance: a "999" read can't separate them, their looks can
        lineup = {"red": [78, 9997, 9991], "blue": []}
        a, b, c = path("red", 0, 300, y=50), path("red", 0, 300, y=150), path("red", 0, 300, y=250)
        a.votes[78] += 3
        sims = {(id(b), 9997): 0.92, (id(b), 9991): 0.70, (id(c), 9997): 0.88, (id(c), 9991): 0.86}
        look = lambda ch, team: sims.get((id(ch[0]), team))
        chains, owner, how = metrics.identify([a, b, c], lineup, look)
        got = {chains[i][0] is b and "b" or chains[i][0] is c and "c" or "a": (t, how[i]) for i, t in owner.items()}
        self.assertEqual(got["a"], (78, "number"))
        self.assertEqual(got["b"], (9997, "look"))
        self.assertEqual(got["c"], (9991, "left"))   # too close to call by look, but the only one left
        # Without looks, b and c stay unknown
        _, owner, _ = metrics.identify([a, b, c], lineup)
        self.assertEqual(len(owner), 1)

    def test_only_clear_reads_teach_looks(self):
        lineup = {"red": [1, 2, 3], "blue": []}
        clear, weak, mixed = path("red", 0, 300, y=50), path("red", 0, 300, y=150), path("red", 0, 300, y=250)
        clear.votes[1] += 3
        weak.votes[2] += 0.4
        mixed.votes[3] += 2
        mixed.votes[1] += 1.5
        chains, owner, how = metrics.identify([clear, weak, mixed], lineup)
        self.assertEqual([t for t, _ in metrics.sure_chains(chains, owner, how)], [1])

    def test_elimination_teaches_when_both_others_are_sure(self):
        lineup = {"red": [1, 2, 3], "blue": []}
        a, b, c = path("red", 0, 300, y=50), path("red", 0, 300, y=150), path("red", 0, 300, y=250)
        a.votes[1] += 3
        b.votes[2] += 3
        chains, owner, how = metrics.identify([a, b, c], lineup)
        self.assertEqual(sorted(t for t, _ in metrics.sure_chains(chains, owner, how, lineup)), [1, 2, 3])
        b.votes[2] = 0.4                            # 2 only weakly read: 3 can't be sure either
        chains, owner, how = metrics.identify([a, b, c], lineup)
        self.assertEqual(sorted(t for t, _ in metrics.sure_chains(chains, owner, how, lineup)), [1])

    def test_gallery_roundtrip(self):
        import tempfile
        import numpy as np
        from rsvision import appearance
        with tempfile.TemporaryDirectory() as d:
            gal = appearance.Gallery(2026, path=f"{d}/2026.npz")
            lineup = {"red": [1, 2, 3], "blue": []}
            k = path("red", 0, 300, y=50)
            k.votes[1] += 3
            k.looks = [np.eye(8, dtype=np.float16)[0]]
            self.assertEqual(gal.learn("2026test", "qm1", [k], lineup), 1)
            self.assertEqual(gal.learn("2026test", "qm1", [k], lineup), 1)   # a re-run replaces, not adds
            gal.save()
            again = appearance.Gallery(2026, path=f"{d}/2026.npz")
            self.assertEqual(len(again.entries), 1)
            self.assertAlmostEqual(again.score(np.eye(8)[0], 1, "2026test"), 1.0, places=3)
            self.assertIsNone(again.score(np.eye(8)[0], 2, "2026test"))   # no looks for team 2 yet
            again.reset()
            self.assertFalse((appearance.Path(d) / "2026.npz").exists())


class MetricsTests(unittest.TestCase):
    def test_left_zone_distance_and_zones(self):
        k = path("red", 20, D + 100, 0, 20)        # drives out in auto, then sits still
        k2 = path("red", D + 100, D + 100, 20.5, 160)
        times = k.t + k2.t
        xy = k.xy + k2.xy
        m = metrics.robot_metrics(times, xy, "red", G)
        self.assertTrue(m["auto_left_zone"])
        self.assertAlmostEqual(m["auto_distance_ft"], (D + 80) / 12, delta=1.5)
        self.assertGreater(m["neutral_zone_s"], 130)
        self.assertGreaterEqual(m["longest_still_s"], 100)   # parked from 21 s until endgame
        self.assertGreater(m["visible_share"], 0.95)

    def test_blue_stays_home(self):
        k = path("blue", L - 30, L - 40, 0, 20)
        m = metrics.robot_metrics(k.t, k.xy, "blue", G)
        self.assertFalse(m["auto_left_zone"])
        self.assertLess(m["visible_share"], 0.2)

    def test_contacts(self):
        secs = {1: {s: (300.0, 100.0) for s in range(10)}, 4: {s: (320.0, 100.0) for s in range(3, 6)}}
        c = metrics.contacts(secs, {1: "red", 4: "blue"}, 40)
        self.assertEqual(c[1], 1)
        self.assertEqual(c[4], 1)

    def test_official_fuel(self):
        bd = {"autoTowerRobot1": "Level1", "autoTowerRobot2": "None", "autoTowerRobot3": "None",
              "endGameTowerRobot1": "Level3", "endGameTowerRobot2": "Level1", "endGameTowerRobot3": "None",
              "foulPoints": 5}
        self.assertEqual(metrics.official_fuel(120, bd, G), 120 - 15 - 30 - 10 - 5)
        self.assertIsNone(metrics.official_fuel(120, {"foulPoints": 5}, G))

    def test_fuel_goes_to_the_robot_in_its_zone(self):
        # Robot 1 sits in red's zone the whole match; 2 is in the neutral zone; 3 is never seen
        secs = {1: {s: (60.0, 100.0) for s in range(161)}, 2: {s: (L / 2, 100.0) for s in range(161)}}
        tl = [[s, s, 0] for s in range(161)]           # red scores 1 a second
        out = metrics.attribute_fuel(tl, "red", secs, [1, 2, 3], G, total=100)
        self.assertGreater(out[1][0], out[3][0])
        self.assertGreater(out[3][0], out[2][0])
        self.assertAlmostEqual(sum(v[1] for v in out.values()), 100, delta=0.5)

    def test_confidence(self):
        self.assertEqual(metrics.confidence(1.0, 1.0), 1.0)
        self.assertEqual(metrics.confidence(0.8, 0.0), 0.4)


class PrelabelTests(unittest.TestCase):
    """Pre-labeling's checks, on drawn frames. The detectors themselves need a GPU and aren't tested."""

    @staticmethod
    def frame(bumper_bgr=None):
        import numpy as np
        f = np.full((1080, 1920, 3), 70, np.uint8)            # gray carpet
        if bumper_bgr:
            import cv2
            cv2.rectangle(f, (500, 500), (600, 600), bumper_bgr, 8)   # a bumper ring
        return f

    class Finder:
        def __init__(self, dets):
            self.dets = dets

        def robots(self, frame):
            return self.dets

    def test_yolo_line(self):
        from rsvision import prelabel
        self.assertEqual(prelabel.yolo_line(1, (0, 0, 960, 540), 1920, 1080),
                         "1 0.250000 0.250000 0.500000 0.500000")

    def test_bumper_color(self):
        from rsvision import prelabel
        box = (490, 490, 610, 610)
        self.assertEqual(prelabel.bumper_color(self.frame((30, 30, 220)), box), "red")
        self.assertEqual(prelabel.bumper_color(self.frame((200, 80, 20)), box), "blue")
        self.assertIsNone(prelabel.bumper_color(self.frame(), box))   # no fabric: a logo or person

    def test_graphics_screen(self):
        import numpy as np
        from rsvision import prelabel
        self.assertFalse(prelabel.graphics_screen(self.frame((30, 30, 220))))
        results = np.zeros((1080, 1920, 3), np.uint8)
        results[:, :960] = (200, 80, 20)
        results[:, 960:] = (30, 30, 220)
        self.assertTrue(prelabel.graphics_screen(results))

    def test_label_frame_filters(self):
        from rsvision import prelabel
        f = self.frame((30, 30, 220))
        robot = (490, 490, 610, 610)
        dets = [
            (robot, 0.3, None),
            ((500, 500, 560, 560), 0.2, None),     # part of the same robot
            ((0, 0, 1920, 1080), 0.5, None),       # the whole field
            (robot, 0.6, "skip"),                  # a person found there first wins
        ]
        self.assertEqual(prelabel.label_frame(f, self.Finder(dets)), [])
        out = prelabel.label_frame(f, self.Finder(dets[:3]))
        self.assertEqual([(c, b) for c, b, _ in out], [("red", robot)])


if __name__ == "__main__":
    unittest.main()


class RobotRowsTest(unittest.TestCase):
    def test_end_to_end_rows(self):
        from rsvision import pipeline
        lineup = {"red": [1307, 1729, 5687], "blue": [4, 5, 6]}
        ks = []
        for i, team in enumerate(lineup["red"]):
            k = path("red", 40, 120, y=60.0 + 90 * i)
            k.votes[team] += 2
            ks.append(k)
        b = path("blue", L - 40, L - 200, y=150)
        b.votes[4] += 2
        ks.append(b)
        bd = {f"autoTowerRobot{i}": "None" for i in (1, 2, 3)}
        bd.update({f"endGameTowerRobot{i}": "None" for i in (1, 2, 3)})
        official = {"red_score": 100, "blue_score": 40, "red_breakdown": bd, "blue_breakdown": bd}
        tl = [[s, int(s * 100 / 160), int(s * 40 / 160)] for s in range(161)]
        rows = pipeline.robot_rows(ks, lineup, tl, official, G)
        by = {r["team_number"]: r for r in rows}
        self.assertEqual(set(by), {1307, 1729, 5687, 4})
        self.assertAlmostEqual(sum(by[t]["data"]["fuel_est"] for t in lineup["red"]), 100, delta=0.5)
        self.assertTrue(all(0 <= r["confidence"] <= 1 for r in rows))
        self.assertEqual(by[4]["alliance"], "blue")
