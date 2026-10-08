from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

import watch_codex  # noqa: E402
from watch_codex import (  # noqa: E402
    CodexWatcher,
    desktop_pids,
    frontmost_pid,
    running_app_pids,
    should_open_pet,
)


class WatcherTests(unittest.TestCase):
    _real_launch_times = staticmethod(watch_codex.desktop_launch_times)
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.visibility_path = Path(temp.name) / "visibility.json"
        launches = patch("watch_codex.desktop_launch_times", return_value={})
        self.addCleanup(launches.stop)
        launches.start()

    def watcher(self) -> CodexWatcher:
        return CodexWatcher(self.visibility_path)

    def suppress(self, pids: list[int]) -> None:
        self.visibility_path.write_text(
            json.dumps({"suppressedCodexPIDs": pids}), encoding="utf-8"
        )

    def test_exact_main_executable_only(self) -> None:
        process_list = """27285 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT
27309 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Service)
28121 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer)
95384 /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
11370 /Users/example/Library/Application Support/CodexQuotaPet/Codex Quota Pet.app/Contents/MacOS/CodexQuotaPet
11371 /private/var/folders/temp/package/Codex Quota Pet.app/Contents/MacOS/CodexQuotaPet
11372 /private/var/folders/temp/package/Codex Quota Pet.app/Contents/MacOS/CodexQuotaPet-helper
"""
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout=process_list, stderr="")
        with patch("watch_codex.subprocess.run", return_value=completed):
            self.assertEqual(desktop_pids(), {27285})
            self.assertEqual(running_app_pids(), ({27285}, {11370, 11371}))

    def test_new_codex_launch_opens_even_when_pet_is_running(self) -> None:
        self.assertTrue(should_open_pet({27285}, set(), {11371}))
        calls: list[str] = []
        watcher = self.watcher()
        opener = lambda: calls.append("open") or True
        self.assertTrue(watcher.observe({27285}, {11371}, 652, 0.0, opener))
        self.assertEqual(calls, ["open"])
        self.assertFalse(watcher.observe({27285}, {11371}, 27285, 1.0, opener))
        self.assertEqual(calls, ["open"])

    def test_new_codex_launch_opens_when_no_pet_is_running(self) -> None:
        self.assertTrue(should_open_pet({27285}, set(), set()))
        self.assertFalse(should_open_pet({27285}, {27285}, set()))

    def test_codex_activation_with_same_pid_reopens_once(self) -> None:
        calls: list[str] = []
        watcher = self.watcher()
        opener = lambda: calls.append("open") or True
        watcher.observe({27285}, {11371}, 652, 0.0, opener)
        # A genuinely later return to Codex, without a new PID, shows it again.
        self.assertTrue(watcher.observe({27285}, {11371}, 27285, 10.0, opener))
        self.assertFalse(watcher.observe({27285}, {11371}, 27285, 11.0, opener))
        self.assertEqual(calls, ["open", "open"])
        watcher.observe({27285}, {11371}, 652, 12.0, opener)
        self.assertTrue(watcher.observe({27285}, {11371}, 27285, 13.0, opener))
        self.assertEqual(calls, ["open", "open", "open"])

    def test_pet_menu_does_not_immediately_undo_manual_hide(self) -> None:
        calls: list[str] = []
        watcher = self.watcher()
        opener = lambda: calls.append("open") or True
        watcher.observe({27285}, {11371}, 27285, 0.0, opener)
        watcher.observe({27285}, {11371}, 11371, 10.0, opener)
        self.assertFalse(watcher.observe({27285}, {11371}, 27285, 10.5, opener))
        self.assertEqual(calls, ["open"])
        watcher.observe({27285}, {11371}, 652, 14.0, opener)
        self.assertTrue(watcher.observe({27285}, {11371}, 27285, 15.0, opener))
        self.assertEqual(calls, ["open", "open"])

    def test_failed_open_retries_three_times_then_stops(self) -> None:
        calls: list[str] = []
        watcher = self.watcher()
        opener = lambda: calls.append("open") or False
        self.assertTrue(watcher.observe({27285}, set(), 652, 0.0, opener))
        self.assertFalse(watcher.observe({27285}, set(), 652, 1.0, opener))
        self.assertTrue(watcher.observe({27285}, set(), 652, 2.0, opener))
        self.assertTrue(watcher.observe({27285}, set(), 652, 4.0, opener))
        self.assertFalse(watcher.observe({27285}, set(), 652, 6.0, opener))
        self.assertEqual(calls, ["open"] * 3)

    def test_successful_open_retries_if_no_pet_process_appears(self) -> None:
        calls: list[str] = []
        watcher = self.watcher()
        opener = lambda: calls.append("open") or True
        self.assertTrue(watcher.observe({27285}, set(), 652, 0.0, opener))
        self.assertFalse(watcher.observe({27285}, set(), 652, 3.9, opener))
        self.assertTrue(watcher.observe({27285}, set(), 652, 4.0, opener))
        self.assertFalse(watcher.observe({27285}, {11371}, 652, 5.0, opener))
        self.assertFalse(watcher.observe({27285}, {11371}, 652, 10.0, opener))
        self.assertEqual(calls, ["open", "open"])

    def test_quit_blocks_same_pid_activation_and_watcher_restart(self) -> None:
        calls: list[str] = []
        opener = lambda: calls.append("open") or True
        watcher = self.watcher()
        self.assertTrue(watcher.observe({27285}, set(), 652, 0.0, opener))
        self.assertEqual(calls, ["open"])

        # The pet records the Codex process that was running when Quit was used.
        self.suppress([27285])
        self.assertFalse(watcher.observe({27285}, set(), 27285, 10.0, opener))
        self.assertIsNone(watcher.pending)

        # The watcher sees the same process as a launch after restarting.
        restarted = self.watcher()
        self.assertFalse(restarted.observe({27285}, set(), 27285, 11.0, opener))
        self.assertIsNone(restarted.pending)
        self.assertEqual(calls, ["open"])

        # A genuinely new desktop process is allowed to request an open.
        self.assertTrue(restarted.observe({27285, 28121}, set(), 27285, 12.0, opener))
        self.assertEqual(calls, ["open", "open"])
        self.assertFalse(self.visibility_path.exists())

    def test_new_pid_preserves_a_concurrent_new_hide(self) -> None:
        real_read = watch_codex._read_visibility_snapshot
        for replacement_pids in ([27285], [27285, 28121]):
            with self.subTest(replacement_pids=replacement_pids):
                self.suppress([27285])
                calls: list[str] = []
                opener = lambda: calls.append("open") or True
                reads = 0

                def read_then_hide(path: Path) -> tuple[bytes, tuple[int, ...]]:
                    nonlocal reads
                    snapshot = real_read(path)
                    reads += 1
                    if reads == 1:
                        # Swift writes Hide atomically. Even an identical new
                        # state is more recent than the watcher's first read.
                        replacement = path.with_suffix(".new")
                        replacement.write_text(
                            json.dumps({"suppressedCodexPIDs": replacement_pids}),
                            encoding="utf-8",
                        )
                        replacement.replace(path)
                    return snapshot

                with patch("watch_codex._read_visibility_snapshot", side_effect=read_then_hide):
                    watcher = self.watcher()
                    self.assertFalse(watcher.observe({27285, 28121}, set(), 652, 0.0, opener))
                self.assertEqual(calls, [])
                self.assertEqual(
                    json.loads(self.visibility_path.read_text(encoding="utf-8")),
                    {"suppressedCodexPIDs": replacement_pids},
                )

    def test_quit_cancels_pending_retry_before_due_time(self) -> None:
        calls: list[str] = []
        opener = lambda: calls.append("open") or False
        watcher = self.watcher()
        self.assertTrue(watcher.observe({27285}, set(), 652, 0.0, opener))
        self.suppress([27285])
        self.assertFalse(watcher.observe({27285}, set(), 652, 1.0, opener))
        self.assertIsNone(watcher.pending)
        self.visibility_path.unlink()
        self.assertFalse(watcher.observe({27285}, set(), 652, 2.0, opener))
        self.assertEqual(calls, ["open"])

    def test_quit_arriving_at_open_boundary_blocks_command(self) -> None:
        calls: list[str] = []
        opener = lambda: calls.append("open") or True
        real_check = watch_codex.is_open_suppressed
        checks = 0

        def check_then_hide(pids: set[int], path: Path) -> bool:
            nonlocal checks
            checks += 1
            if checks == 1:
                self.suppress([27285])
                return False
            return real_check(pids, path)

        with patch("watch_codex.is_open_suppressed", side_effect=check_then_hide):
            watcher = self.watcher()
            self.assertFalse(watcher.observe({27285}, set(), 652, 0.0, opener))
        self.assertEqual(calls, [])
        self.assertIsNone(watcher.pending)

    def test_empty_or_malformed_visibility_state_blocks_open(self) -> None:
        for state in (
            '{"suppressedCodexPIDs": []}',
            "{bad json",
            '{"suppressedCodexPIDs": [true]}',
            '{"otherKey": [27285]}',
        ):
            with self.subTest(state=state):
                self.visibility_path.write_text(state, encoding="utf-8")
                for pids in ({27285}, {27285, 28121}):
                    calls: list[str] = []
                    watcher = self.watcher()
                    opener = lambda: calls.append("open") or True
                    self.assertFalse(watcher.observe(pids, set(), 652, 0.0, opener))
                    self.assertIsNone(watcher.pending)
                    self.assertEqual(calls, [])

    def test_frontmost_pid_uses_lsappinfo_asn_and_pid(self) -> None:
        front = subprocess.CompletedProcess(args=[], returncode=0, stdout="ASN:0x0-0xc00c:\n", stderr="")
        info = subprocess.CompletedProcess(args=[], returncode=0, stdout='"pid"=27285\n', stderr="")
        with patch("watch_codex.subprocess.run", side_effect=[front, info]) as run:
            self.assertEqual(frontmost_pid(), 27285)
        self.assertEqual(run.call_args_list[0].args[0], ["/usr/bin/lsappinfo", "front"])
        self.assertEqual(
            run.call_args_list[1].args[0],
            ["/usr/bin/lsappinfo", "info", "-only", "pid", "ASN:0x0-0xc00c:"],
        )

    def test_frontmost_pid_returns_unknown_on_query_error(self) -> None:
        with patch("watch_codex.subprocess.run", side_effect=OSError("unavailable")):
            self.assertIsNone(frontmost_pid())

    def test_launch_time_query_is_strict_and_scoped_to_desktop_pids(self) -> None:
        listing = "101 Thu Oct  1 16:33:32 2026\n102 invalid\n103 Fri Oct 1 16:33:32 2026\n999 Thu Oct 1 16:33:32 2026"
        result = subprocess.CompletedProcess(args=[], returncode=0, stdout=listing)
        from datetime import datetime
        with patch("watch_codex.subprocess.run", return_value=result) as run:
            actual = self._real_launch_times({101, 102, 103})
        self.assertEqual(actual, {101: datetime(2026, 10, 1, 16, 33, 32).timestamp()})
        self.assertEqual(run.call_args.kwargs["env"]["LC_ALL"], "C")
        self.assertIn("101,102,103", run.call_args.args[0])

    def test_new_launch_proof_preserves_a_concurrent_empty_hide(self) -> None:
        self.suppress([])
        real_read = watch_codex._read_visibility_snapshot
        reads = 0
        def read_then_replace(path):
            nonlocal reads
            snapshot = real_read(path)
            reads += 1
            if reads == 1:
                replacement = path.with_suffix(".new")
                replacement.write_text('{"suppressedCodexPIDs":[]}')
                replacement.replace(path)
            return snapshot
        with patch("watch_codex._read_visibility_snapshot", side_effect=read_then_replace):
            self.assertTrue(watch_codex.is_open_suppressed({101}, self.visibility_path, {101: 9999999999}))
        self.assertTrue(self.visibility_path.exists())


if __name__ == "__main__":
    unittest.main()
