from __future__ import annotations

import io
import plistlib
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import install_launch_agent as installer  # noqa: E402


class InstallLaunchAgentTests(unittest.TestCase):
    def test_custom_paths_install_and_same_path_reinstall(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source_app = root / "download" / "Codex Quota Pet.app"
            contents = source_app / "Contents"
            contents.mkdir(parents=True)
            (contents / "Info.plist").write_text("fixture", encoding="utf-8")
            (contents / "payload.txt").write_text("pet app", encoding="utf-8")
            source_watcher = root / "download" / "watch_codex.py"
            source_watcher.write_text("# test watcher\n", encoding="utf-8")

            support = root / "Application Support" / "CodexQuotaPet"
            installed_app = support / "Codex Quota Pet.app"
            installed_watcher = support / "watch_codex.py"
            plist_path = root / "LaunchAgents" / "com.codexquotapet.watcher.plist"
            completed = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
            patches = (
                patch.object(installer, "SUPPORT_DIR", support),
                patch.object(installer, "INSTALLED_APP", installed_app),
                patch.object(installer, "INSTALLED_WATCHER", installed_watcher),
                patch.object(installer, "PLIST_PATH", plist_path),
                patch.object(installer.subprocess, "run", return_value=completed),
            )
            with patches[0], patches[1], patches[2], patches[3], patches[4] as launchctl:
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(
                        installer.main(["--app", str(source_app), "--watcher", str(source_watcher)]),
                        0,
                    )
                self.assertEqual((installed_app / "Contents" / "payload.txt").read_text(), "pet app")
                self.assertEqual(installed_watcher.read_text(), "# test watcher\n")
                plist = plistlib.loads(plist_path.read_bytes())
                self.assertEqual(plist["ProgramArguments"], ["/usr/bin/python3", str(installed_watcher)])
                self.assertTrue(plist["RunAtLoad"])

                app_inode = installed_app.stat().st_ino
                watcher_inode = installed_watcher.stat().st_ino
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(
                        installer.main(["--app", str(installed_app), "--watcher", str(installed_watcher)]),
                        0,
                    )
                self.assertEqual(installed_app.stat().st_ino, app_inode)
                self.assertEqual(installed_watcher.stat().st_ino, watcher_inode)
                self.assertEqual((installed_app / "Contents" / "payload.txt").read_text(), "pet app")
                self.assertEqual(launchctl.call_count, 4)

    def test_missing_bundle_does_not_activate(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            source_watcher = Path(temp) / "watch_codex.py"
            source_watcher.write_text("# watcher\n", encoding="utf-8")
            with patch.object(installer.subprocess, "run") as launchctl:
                self.assertEqual(
                    installer.main(["--app", str(Path(temp) / "missing.app"), "--watcher", str(source_watcher)]),
                    1,
                )
                launchctl.assert_not_called()


if __name__ == "__main__":
    unittest.main()
