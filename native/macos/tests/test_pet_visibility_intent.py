"""Exercise visibility persistence across independent pet process launches."""

import json
import os
import pathlib
import subprocess
import tempfile
import unittest
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import watch_codex


class PetVisibilityIntentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary_dir = tempfile.TemporaryDirectory(prefix="pet-visibility-binary-")
        cls.binary = pathlib.Path(cls.binary_dir.name) / "visibility-harness"
        subprocess.run(
            [
                "swiftc",
                "-swift-version",
                "5",
                str(ROOT / "app" / "PetVisibilityIntent.swift"),
                str(ROOT / "tests" / "PetVisibilityIntentHarness.swift"),
                "-o",
                str(cls.binary),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )

    @classmethod
    def tearDownClass(cls):
        cls.binary_dir.cleanup()

    def run_pet(self, action, store, pids=(), launch_time=None):
        pid_arg = ",".join(str(pid) for pid in pids) or "-"
        result = subprocess.run(
            [str(self.binary), action, str(store), pid_arg] +
            ([] if launch_time is None else [str(launch_time)]),
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return result.stdout.strip()

    def test_swift_harness_json_round_trip(self):
        result = subprocess.run(
            [str(self.binary), "selftest"],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertIn("PetVisibilityIntent PASS", result.stdout)

    def test_hide_survives_restarts_and_same_codex_pid(self):
        with tempfile.TemporaryDirectory(prefix="pet-visibility-") as temp_dir:
            store = pathlib.Path(temp_dir) / "Support" / "visibility.json"
            self.assertEqual(self.run_pet("check", store, [101]), "SHOW")
            self.assertFalse(store.exists())

            self.assertEqual(self.run_pet("hide", store, [101]), "HIDDEN")
            self.assertEqual(json.loads(store.read_text())["suppressedCodexPIDs"], [101])
            self.assertIsInstance(json.loads(store.read_text())["recordedAt"], float)
            self.assertEqual(self.run_pet("check", store, [101]), "HIDDEN")
            self.assertEqual(self.run_pet("check", store), "HIDDEN")  # temporary discovery gap
            self.assertEqual(self.run_pet("check", store, [101]), "HIDDEN")
            self.assertEqual(self.run_pet("check", store, [202]), "SHOW")
            self.assertFalse(store.exists())

    def test_quit_suppression_persists_and_new_instance_clears_it(self):
        with tempfile.TemporaryDirectory(prefix="pet-visibility-") as temp_dir:
            store = pathlib.Path(temp_dir) / "visibility.json"
            self.run_pet("quit", store, [101, 102])
            self.assertEqual(json.loads(store.read_text())["suppressedCodexPIDs"], [101, 102])
            self.assertEqual(self.run_pet("check", store, [101, 102]), "HIDDEN")
            self.assertEqual(self.run_pet("check", store, [101, 102, 303]), "SHOW")
            self.assertFalse(store.exists())

    def test_empty_pid_suppression_requires_explicit_show(self):
        with tempfile.TemporaryDirectory(prefix="pet-visibility-") as temp_dir:
            store = pathlib.Path(temp_dir) / "visibility.json"
            self.run_pet("hide", store)
            self.assertEqual(json.loads(store.read_text())["suppressedCodexPIDs"], [])
            self.assertEqual(self.run_pet("check", store), "HIDDEN")
            self.assertEqual(self.run_pet("check", store, [404]), "HIDDEN")
            self.assertEqual(self.run_pet("show", store), "SHOW")
            self.assertFalse(store.exists())
            self.assertEqual(self.run_pet("check", store, [404]), "SHOW")

    def test_present_but_malformed_state_stays_hidden(self):
        with tempfile.TemporaryDirectory(prefix="pet-visibility-") as temp_dir:
            store = pathlib.Path(temp_dir) / "visibility.json"
            store.write_text("not valid json")
            self.assertEqual(self.run_pet("check", store, [101]), "HIDDEN")
            self.assertEqual(self.run_pet("show", store), "SHOW")
            self.assertFalse(store.exists())

    def test_launch_time_proof_agrees_across_languages(self):
        for contents in ('{"suppressedCodexPIDs":[]}', 'broken JSON',
                         '{"suppressedCodexPIDs":[],"recordedAt":Infinity}',
                         '{"suppressedCodexPIDs":[],"recordedAt":NaN}'):
            for launch_time in (None, 999, 1000, 1001.9, 1002, 2000):
                with self.subTest(contents=contents, launch_time=launch_time), tempfile.TemporaryDirectory() as temp_dir:
                    store = pathlib.Path(temp_dir) / "visibility.json"
                    store.write_text(contents)
                    os.utime(store, (1000, 1000))
                    expected_show = launch_time is not None and launch_time >= 1002
                    launches = {} if launch_time is None else {404: launch_time}
                    self.assertEqual(watch_codex.is_open_suppressed({404}, store, launches), not expected_show)
                    store.write_text(contents)
                    os.utime(store, (1000, 1000))
                    self.assertEqual(self.run_pet("check", store, [404], launch_time),
                                     "SHOW" if expected_show else "HIDDEN")

    def test_swift_recorded_time_is_understood_by_watcher(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = pathlib.Path(temp_dir) / "visibility.json"
            self.run_pet("hide", store)
            recorded = json.loads(store.read_text())["recordedAt"]
            # Copying/touching backwards must not replace the newer saved time.
            os.utime(store, (1000, 1000))
            self.assertTrue(watch_codex.is_open_suppressed({404}, store, {404: recorded + 1}))
            self.assertEqual(self.run_pet("check", store, [404], recorded + 1), "HIDDEN")
            self.assertFalse(watch_codex.is_open_suppressed({404}, store, {404: recorded + 3}))


if __name__ == "__main__":
    unittest.main()
