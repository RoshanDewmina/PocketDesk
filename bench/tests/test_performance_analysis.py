import importlib.util
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
from io import StringIO
import json


BENCH = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH))


def load(name):
    spec = importlib.util.spec_from_file_location(name, BENCH / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


align = load("align_exports")
summary = load("ab_summary")
recording = load("analyze")
stats_summary = load("stats_summary")


class TimestampTests(unittest.TestCase):
    def test_parses_iso_and_epoch_units(self):
        expected = 1_799_798_400.25
        self.assertAlmostEqual(align.parse_time("2027-01-13T00:00:00.250Z"), expected)
        self.assertAlmostEqual(align.parse_time(expected * 1_000), expected)
        self.assertAlmostEqual(align.parse_time(expected * 1_000_000), expected)
        self.assertAlmostEqual(align.parse_time(expected * 1_000_000_000), expected, places=6)

    def test_host_summary_age_changes_pairing_target(self):
        row = {"at": "2027-01-13T00:00:10Z", "hostSummaryAgeMs": 750}
        self.assertAlmostEqual(align.host_time_for_phone(row), 1_799_798_409.25)

    def test_timestamp_pairing_is_monotonic_and_uses_age(self):
        mac = [(1, {"at": 100.0}), (2, {"at": 101.0}), (3, {"at": 102.0})]
        phone = [(1, {"at": 100.4, "hostSummaryAgeMs": 400}),
                 (2, {"at": 101.3, "hostSummaryAgeMs": 300}),
                 (3, {"at": 102.2, "hostSummaryAgeMs": 200})]
        self.assertEqual([(p, m) for p, m, _ in align.timestamp_pairs(phone, mac)],
                         [(0, 0), (1, 1), (2, 2)])

    def test_timestamp_cli_does_not_extrapolate_unpaired_mark(self):
        with tempfile.TemporaryDirectory() as directory:
            phone_path = pathlib.Path(directory) / "phone.jsonl"
            mac_path = pathlib.Path(directory) / "mac.jsonl"
            phone = [{"at": 100.0}, {"at": 102.0}, {"at": 103.0}]
            mac = [{"at": 100.0}, {"at": 101.0}, {"at": 102.0}, {"at": 103.0}]
            phone_path.write_text("".join(json.dumps(row) + "\n" for row in phone))
            mac_path.write_text("".join(json.dumps(row) + "\n" for row in mac))
            output = StringIO()
            with redirect_stdout(output):
                status = align.main([str(phone_path), "0", "3", str(mac_path), "1", "4", "2"])
            self.assertEqual(status, 0)
            self.assertIn("mac line 2 -> unpaired", output.getvalue())

    def test_repeated_fps_alignment_is_rejected_as_ambiguous(self):
        candidates = [(0, 1.0, 50), (1, 1.0, 49), (2, 0.7, 48)]
        chosen, reason = align.choose_legacy(candidates)
        self.assertIsNone(chosen)
        self.assertIn("ambiguous", reason)


class SummaryWindowTests(unittest.TestCase):
    @staticmethod
    def row(at, distinct, glass, uncertainty=1.5):
        return {
            "role": "phone", "at": at, "decodedFPS": 60, "presentedFPS": 60,
            "markerDistinctFPS": distinct, "glassP50Ms": glass,
            "glassP95Ms": glass + 10, "clockUncertaintyMs": uncertainty,
            "renderGapMaxMs": 20, "host": {},
        }

    def test_idle_marker_age_never_enters_latency(self):
        rows = [self.row(100, 0, 20_000), self.row(101, 40, 35)]
        result = summary.summarize("run", rows, 30, 20, all_active=True)
        self.assertEqual(result["cadence s"], 2)
        self.assertEqual(result["marker motion s"], 1)
        self.assertEqual(result["marker p50/p95 uncal"], "35/45")
        self.assertEqual(result["physical latency"], "needs camera calibration")

    def test_uncertain_or_missing_clock_excludes_marker_latency(self):
        rows = [self.row(100, 40, 35, uncertainty=None),
                self.row(101, 40, 36, uncertainty=-1),
                self.row(102, 40, 37, uncertainty=float("nan"))]
        result = summary.summarize("run", rows, 30, 20)
        self.assertEqual(result["clocked marker s"], 0)
        self.assertEqual(result["marker p50/p95 uncal"], "–/–")

    def test_iso_time_window_and_last_seconds(self):
        rows = [self.row("2027-01-13T00:00:00Z", 30, 30),
                self.row("2027-01-13T00:00:01Z", 30, 31),
                self.row("2027-01-13T00:00:02Z", 30, 32)]
        start = align.parse_time("2027-01-13T00:00:01Z")
        self.assertEqual(len(summary.select_time(rows, start, None)), 2)
        self.assertEqual(summary.select_last(rows, 1), rows[1:])

    def test_two_files_support_time_and_row_windows_together(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = []
            for name in ("first", "second"):
                path = pathlib.Path(directory) / f"{name}.jsonl"
                with path.open("w") as handle:
                    for offset in range(4):
                        row = self.row(f"2027-01-13T00:00:0{offset}Z", 30, 30 + offset)
                        handle.write(json.dumps(row) + "\n")
                paths.append(path)
            output = StringIO()
            with redirect_stdout(output):
                status = summary.main([
                    f"one={paths[0]}", f"two={paths[1]}",
                    "--from=2027-01-13T00:00:01Z", "--to=2027-01-13T00:00:04Z",
                    "--rows=1:3",
                ])
            self.assertEqual(status, 0)
            text = output.getvalue()
            self.assertIn("one", text)
            self.assertIn("two", text)
            self.assertIn("samples", text)

    def test_invalid_time_bound_fails_closed(self):
        self.assertEqual(summary.main(["--from=not-a-date"]), 2)

    def test_stats_summary_filters_idle_marker_age(self):
        rows = [self.row(100, 0, 20_000), self.row(101, 40, 35),
                self.row(102, 40, 90, uncertainty=-1)]
        self.assertEqual(stats_summary.field_values(rows, "phone", "glassP50Ms"), [35])


class RecordingCadenceTests(unittest.TestCase):
    def test_failed_recording_analysis_has_nonzero_exit(self):
        with patch.object(recording, "source_times", side_effect=RuntimeError("unreadable recording")):
            self.assertEqual(recording.main(["sample=missing.mp4"]), 2)

    def test_invalid_recording_window_is_rejected_before_reading(self):
        with patch.object(recording, "source_times") as source:
            self.assertEqual(recording.main(["sample=missing.mp4", "--dur=-1"]), 2)
            source.assert_not_called()

    def test_fps_uses_intervals_not_frame_count(self):
        values = [index / 60 for index in range(61)]
        result = recording.cadence_stats(values)
        self.assertAlmostEqual(result["fps"], 60.0)
        self.assertAlmostEqual(result["median"], 1000 / 60)

    def test_vfr_pts_reports_actual_cadence_and_gap(self):
        values = [0, 0.016, 0.033, 0.050, 0.083, 0.100, 0.117]
        result = recording.cadence_stats(values)
        self.assertAlmostEqual(result["fps"], 6 / 0.117)
        self.assertAlmostEqual(result["p90"], 33.0)

    def test_duplicate_or_reversed_pts_are_rejected(self):
        values = [0, 0.016, 0.016, 0.010, 0.033, 0.050, 0.066, 0.083, 0.100]
        with self.assertRaisesRegex(ValueError, "strictly increasing"):
            recording.cadence_stats(values)

    def test_long_stall_is_retained(self):
        values = [0, 0.016, 0.033, 0.050, 0.066, 1.266, 1.283]
        result = recording.cadence_stats(values)
        self.assertEqual(result["stalls"], 1)
        self.assertEqual(result["p99"], 1200.0)

    def test_ffprobe_keyframe_lead_is_trimmed_to_requested_window(self):
        payload = {"frames": [
            {"best_effort_timestamp_time": "8.0"},
            {"best_effort_timestamp_time": "10.0"},
            {"best_effort_timestamp_time": "10.5"},
            {"best_effort_timestamp_time": "12.0"},
        ]}
        completed = type("Completed", (), {
            "returncode": 0, "stdout": json.dumps(payload), "stderr": ""
        })()
        with patch.object(recording, "run", return_value=completed):
            self.assertEqual(recording.source_times("capture.mp4", 10, 2), [10.0, 10.5])


if __name__ == "__main__":
    unittest.main()
