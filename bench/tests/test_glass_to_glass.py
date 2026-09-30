import importlib.util
import pathlib
import random
import shutil
import subprocess
import sys
import tempfile
import unittest

BENCH = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH))
spec = importlib.util.spec_from_file_location("glass_to_glass", BENCH / "glass_to_glass.py")
g2g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g2g)

FPS = 240
DARK, BRIGHT = 20, 230


def schedule(seed, seconds, delays_ms):
    rng = random.Random(seed)
    mac, time = [], 0.3
    while time < seconds - 0.8:
        mac.append(time)
        time += rng.uniform(0.4, 0.7)
    phone = [t + delays_ms[i % len(delays_ms)] / 1000 for i, t in enumerate(mac)]
    return mac, phone


def bright_fraction(toggles, start, end):
    """Share of [start, end) spent bright, for a signal that starts dark and flips at each toggle."""
    edges = [start] + [t for t in toggles if start < t < end] + [end]
    state = sum(1 for t in toggles if t <= start) % 2 == 1
    lit = 0.0
    for a, b in zip(edges, edges[1:]):
        if state:
            lit += b - a
        state = not state
    return lit / (end - start)


def samples_for(toggles, seconds):
    frames = int(seconds * FPS)
    return [(k / FPS, DARK + (BRIGHT - DARK) * bright_fraction(toggles, k / FPS, (k + 1) / FPS))
            for k in range(frames)]


class TransitionTests(unittest.TestCase):
    def test_detects_each_toggle_with_direction(self):
        mac, _ = schedule(1, 6, [40])
        found = g2g.transitions(samples_for(mac, 6))
        self.assertEqual(len(found), len(mac))
        self.assertEqual([rising for _, rising in found], [i % 2 == 0 for i in range(len(mac))])
        for (time, _), truth in zip(found, mac):
            self.assertLess(abs(time - truth), 1.5 / FPS)

    def test_flat_signal_has_no_transitions(self):
        self.assertEqual(g2g.transitions([(k / FPS, 100.0) for k in range(100)]), [])

    def test_noise_inside_the_hysteresis_band_is_ignored(self):
        mac, _ = schedule(2, 4, [40])
        rng = random.Random(3)
        noisy = [(t, v + rng.uniform(-15, 15)) for t, v in samples_for(mac, 4)]
        self.assertEqual(len(g2g.transitions(noisy)), len(mac))


class PairingTests(unittest.TestCase):
    def test_recovers_known_delays_to_sub_frame_precision(self):
        delays = [37.5, 41.0, 52.1, 33.3, 45.8]
        mac, phone = schedule(4, 10, delays)
        result = g2g.analyze(samples_for(mac, 10), samples_for(phone, 10))
        stats = result["glassToGlassMs"]
        self.assertEqual(stats["n"], len(mac))
        self.assertEqual(result["unpaired"], 0)
        truth = sorted(delays[i % len(delays)] for i in range(len(mac)))
        self.assertAlmostEqual(stats["p50"], g2g.percentile(truth, 0.5), delta=2.5)
        self.assertAlmostEqual(stats["max"], max(truth), delta=2.5)

    def test_missing_phone_transition_is_counted_not_misattributed(self):
        mac, phone = schedule(5, 6, [40])
        dropped = phone[:3] + phone[5:]
        pairs, missing = g2g.pair(g2g.transitions(samples_for(mac, 6)),
                                  [(t, i % 2 == 0) for i, t in enumerate(phone) if t in dropped], 0.4)
        self.assertEqual(missing, 2)
        self.assertTrue(all(abs(delay - 40) < 5 for _, _, delay in pairs))

    def test_phone_transition_after_the_next_mac_toggle_is_not_paired(self):
        pairs, missing = g2g.pair([(1.0, True), (1.2, False)], [(1.25, True), (1.3, False)], 0.4)
        self.assertEqual([round(d) for _, _, d in pairs], [100])
        self.assertEqual(missing, 1)

    def test_touch_times_measure_to_the_next_transition_on_each_screen(self):
        rows = g2g.touch_latencies([1.0], [(1.05, True)], [(1.09, True)])
        self.assertAlmostEqual(rows[0]["toMacMs"], 50)
        self.assertAlmostEqual(rows[0]["toPhoneMs"], 90)

    def test_region_accepts_fractions_and_pixels(self):
        self.assertEqual(g2g.parse_region("0.5,0,0.25,0.5", 200, 100), (100, 0, 50, 50))
        self.assertEqual(g2g.parse_region("10,20,30,40", 200, 100), (10, 20, 30, 40))
        with self.assertRaises(ValueError):
            g2g.parse_region("150,0,100,10", 200, 100)

    def test_metadata_parser_pairs_times_and_luma(self):
        text = ("frame:0    pts:0       pts_time:0\nlavfi.signalstats.YAVG=16.5\n"
                "frame:1    pts:1       pts_time:0.00416667\nlavfi.signalstats.YAVG=200\n")
        self.assertEqual(g2g.parse_metadata(text), [(0.0, 16.5), (0.00416667, 200.0)])


@unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "needs ffmpeg")
class ClipTests(unittest.TestCase):
    def test_end_to_end_on_a_synthetic_240fps_clip(self):
        width, height, seconds = 160, 90, 8
        delays = [38.0, 44.0, 51.0]
        mac, phone = schedule(6, seconds, delays)
        rows = bytearray()
        for k in range(int(seconds * FPS)):
            left = int(DARK + (BRIGHT - DARK) * bright_fraction(mac, k / FPS, (k + 1) / FPS))
            right = int(DARK + (BRIGHT - DARK) * bright_fraction(phone, k / FPS, (k + 1) / FPS))
            row = bytes([left] * (width // 2) + [right] * (width // 2))
            rows += row * height
        with tempfile.TemporaryDirectory() as directory:
            clip = pathlib.Path(directory) / "clip.nut"
            encode = subprocess.run(
                ["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{width}x{height}",
                 "-r", str(FPS), "-i", "-", "-c:v", "ffv1", str(clip)],
                input=bytes(rows), capture_output=True, check=False)
            self.assertEqual(encode.returncode, 0, encode.stderr.decode())
            out = pathlib.Path(directory) / "result.json"
            status = g2g.main([str(clip), "--mac", "0.1,0.2,0.3,0.6", "--phone", "0.6,0.2,0.3,0.6",
                               "--json", str(out)])
            self.assertEqual(status, 0)
            import json
            result = json.loads(out.read_text())
        stats = result["glassToGlassMs"]
        self.assertEqual(stats["n"], len(mac))
        truth = sorted(delays[i % len(delays)] for i in range(len(mac)))
        self.assertAlmostEqual(stats["p50"], g2g.percentile(truth, 0.5), delta=2.5)
        self.assertAlmostEqual(result["frameIntervalMs"], 1000 / FPS, delta=0.1)


if __name__ == "__main__":
    unittest.main()
