"""Real AppKit edge placement regression; requires a macOS desktop session."""

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ParticlePanelTests(unittest.TestCase):
    def test_actual_appkit_particle_positions(self):
        with tempfile.TemporaryDirectory(prefix="pet-panel-placement-") as directory:
            executable = Path(directory) / "particle-panel"
            subprocess.run(
                ["swiftc", "-swift-version", "5", "-O", "-framework", "AppKit",
                 "-framework", "ImageIO", str(ROOT / "app" / "ParticlePanel.swift"),
                 str(ROOT / "app" / "BounceMotion.swift"),
                 str(ROOT / "tests" / "ParticlePanelHarness.swift"), "-o", str(executable)],
                check=True, capture_output=True, text=True, timeout=60,
            )
            result = subprocess.run([str(executable)], check=True, capture_output=True,
                                    text=True, timeout=15)
            self.assertIn("ParticlePanel PASS:", result.stdout)
            self.assertIn("zero position corrections", result.stdout)


if __name__ == "__main__":
    unittest.main()
