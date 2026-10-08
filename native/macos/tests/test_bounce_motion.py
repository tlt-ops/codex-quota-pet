"""Exercise the actual Swift particle motion, including edge-stick regressions."""

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class BounceMotionTests(unittest.TestCase):
    def test_swift_bounce_regressions(self):
        with tempfile.TemporaryDirectory(prefix="pet-bounce-motion-") as temporary:
            binary = Path(temporary) / "bounce-motion"
            subprocess.run(
                ["swiftc", "-swift-version", "5", "-O",
                 str(ROOT / "app" / "BounceMotion.swift"),
                 str(ROOT / "tests" / "BounceMotionHarness.swift"), "-o", str(binary)],
                check=True, capture_output=True, text=True, timeout=60,
            )
            result = subprocess.run([str(binary)], check=True, capture_output=True,
                                    text=True, timeout=30)
            self.assertIn("BounceMotion PASS: 6 scenario groups, 2400 seeded trajectories", result.stdout)


if __name__ == "__main__":
    unittest.main()
