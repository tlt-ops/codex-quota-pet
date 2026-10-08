"""Compile and run the Foundation-only Swift sound event detector scenarios."""

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class QuotaSoundEventsTests(unittest.TestCase):
    def test_swift_detector_scenarios(self) -> None:
        with tempfile.TemporaryDirectory(prefix="quota-sound-events-") as temporary:
            executable = Path(temporary) / "quota-sound-events"
            subprocess.run(
                [
                    "swiftc", "-swift-version", "5",
                    str(ROOT / "app" / "QuotaSoundEvents.swift"),
                    str(ROOT / "tests" / "QuotaSoundEventsHarness.swift"),
                    "-o", str(executable),
                ],
                check=True, capture_output=True, text=True,
            )
            completed = subprocess.run(
                [str(executable)], check=True, capture_output=True, text=True,
            )
            self.assertIn("7 scenario groups passed", completed.stdout)


if __name__ == "__main__":
    unittest.main()
