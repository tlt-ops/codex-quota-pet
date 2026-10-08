#!/usr/bin/env python3
"""Show the quota pet when Codex starts or becomes the frontmost app.

The installed desktop app on this Mac uses ChatGPT.app as its bundle. Match
the full main executable path so Codex helpers and CLI processes do not count.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable


def pet_app_path() -> Path:
    """Work from either the source package or its stable installed copy."""
    script_dir = Path(__file__).resolve().parent
    installed = script_dir / "Codex Quota Pet.app"
    if installed.is_dir():
        return installed
    return script_dir.parent / "app" / "Codex Quota Pet.app"


DESKTOP_EXECUTABLES = frozenset(
    {
        "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
        "/Applications/Codex.app/Contents/MacOS/Codex",
    }
)
PET_EXECUTABLE_SUFFIX = "/Codex Quota Pet.app/Contents/MacOS/CodexQuotaPet"
MAX_OPEN_ATTEMPTS = 3
FAILED_OPEN_RETRY_SECONDS = 2.0
PET_APPEAR_GRACE_SECONDS = 4.0
INITIAL_ACTIVATION_GRACE_SECONDS = 3.0
VISIBILITY_STATE_PATH = (
    Path.home() / "Library" / "Application Support" / "CodexQuotaPet" / "visibility.json"
)
_FRONT_ASN = re.compile(r"ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+:")
_INFO_PID = re.compile(r'"pid"=(\d+)\b')


def running_app_pids() -> tuple[set[int], set[int]]:
    """Read exact main executable paths for Codex and any copy of the pet."""
    try:
        result = subprocess.run(
            ["/bin/ps", "-ww", "-axo", "pid=,comm="],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return set(), set()
    codex: set[int] = set()
    pet: set[int] = set()
    for row in result.stdout.splitlines():
        parts = row.strip().split(maxsplit=1)
        if len(parts) != 2:
            continue
        executable = parts[1]
        if executable not in DESKTOP_EXECUTABLES and not executable.endswith(PET_EXECUTABLE_SUFFIX):
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        if executable in DESKTOP_EXECUTABLES:
            codex.add(pid)
        else:
            pet.add(pid)
    return codex, pet


def desktop_pids() -> set[int]:
    return running_app_pids()[0]


def should_open_pet(current_codex: set[int], previous_codex: set[int], _current_pet: set[int]) -> bool:
    # An existing pet may be hidden. Reopening it is the app's job.
    return bool(current_codex - previous_codex)


def _read_visibility_snapshot(visibility_path: Path) -> tuple[bytes, tuple[int, ...]]:
    """Read one file generation, including identity for a guarded removal."""
    with visibility_path.open("rb") as stream:
        metadata = os.fstat(stream.fileno())
        contents = stream.read()
    identity = (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )
    return contents, identity


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"Invalid JSON constant: {value}")


def desktop_launch_times(pids: set[int]) -> dict[int, float]:
    """Query only already identified desktop PIDs; never infer from watcher uptime."""
    if not pids:
        return {}
    try:
        result = subprocess.run(
            ["/bin/ps", "-ww", "-p", ",".join(map(str, sorted(pids))), "-o", "pid=,lstart="],
            check=True, capture_output=True, text=True, timeout=5,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return {}
    launches = {}
    for row in result.stdout.splitlines():
        fields = row.split(maxsplit=1)
        if len(fields) != 2:
            continue
        try:
            pid = int(fields[0])
            normalized = " ".join(fields[1].split())
            date = datetime.strptime(normalized, "%a %b %d %H:%M:%S %Y")
            # strptime tolerates inconsistent weekdays; reject such output.
            if " ".join(date.strftime("%a %b %d %H:%M:%S %Y").split()) != normalized.replace(
                " " + str(date.day) + " ", " " + f"{date.day:02d}" + " ", 1
            ):
                continue
            if pid in pids:
                launches[pid] = date.timestamp()
        except (ValueError, OverflowError, OSError):
            continue
    return launches


def is_open_suppressed(codex_pids: set[int], visibility_path: Path,
                       launch_times: dict[int, float] | None = None) -> bool:
    """Honor Quit, removing only an unchanged state made obsolete by a new PID."""
    try:
        contents, identity = _read_visibility_snapshot(visibility_path)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    try:
        state = json.loads(contents, parse_constant=_reject_json_constant)
    except (UnicodeError, ValueError):
        state = {}

    suppressed = state.get("suppressedCodexPIDs") if isinstance(state, dict) else None
    unknown = not isinstance(suppressed, list) or any(
        type(pid) is not int or pid <= 0 for pid in suppressed
    ) or not suppressed
    if unknown:
        recorded_at = identity[3] / 1_000_000_000
        saved_time = state.get("recordedAt") if isinstance(state, dict) else None
        if type(saved_time) in (int, float) and saved_time == saved_time:
            recorded_at = max(recorded_at, saved_time)
        if launch_times is None:
            launch_times = desktop_launch_times(codex_pids)
        if not any(launch_times.get(pid, float("-inf")) >= recorded_at + 2.0
                   for pid in codex_pids):
            return True
    elif codex_pids.issubset(set(suppressed)):
        return True

    # A new Codex PID makes the old state obsolete. Swift replaces the file
    # atomically on a new Hide, so preserve it if either identity or bytes
    # changed between the decision and the guarded unlink.
    try:
        latest_contents, latest_identity = _read_visibility_snapshot(visibility_path)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    if (latest_contents, latest_identity) != (contents, identity):
        return True
    try:
        visibility_path.unlink()
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return False


def frontmost_pid() -> int | None:
    """Read the front application PID without requiring Accessibility access."""
    try:
        front = subprocess.run(
            ["/usr/bin/lsappinfo", "front"],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
        match = _FRONT_ASN.search(front.stdout)
        if match is None:
            return None
        info = subprocess.run(
            ["/usr/bin/lsappinfo", "info", "-only", "pid", match.group()],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None
    match = _INFO_PID.search(info.stdout)
    return int(match.group(1)) if match is not None else None


@dataclass
class PendingOpen:
    attempts: int
    next_try_at: float
    waiting_for_pet: bool = False


class CodexWatcher:
    """Turn process and activation transitions into bounded open requests."""

    def __init__(self, visibility_path: Path = VISIBILITY_STATE_PATH) -> None:
        self.visibility_path = visibility_path
        self.previous_codex: set[int] = set()
        self.previous_frontmost_pid: int | None = None
        self.recent_launches: dict[int, float] = {}
        self.last_pet_foreground_at: float | None = None
        self.pending: PendingOpen | None = None

    def observe(
        self,
        codex_pids: set[int],
        pet_pids: set[int],
        front_pid: int | None,
        now: float,
        opener: Callable[[], bool] | None = None,
    ) -> bool:
        """Process one sample; return whether an open command was attempted."""
        # The default is resolved at call time so tests can replace open_pet.
        if opener is None:
            opener = open_pet
        new_pids = codex_pids - self.previous_codex
        activated = (
            front_pid is not None
            and front_pid in codex_pids
            and front_pid != self.previous_frontmost_pid
        )
        if front_pid in pet_pids:
            self.last_pet_foreground_at = now
        self.previous_codex = set(codex_pids)
        if front_pid is not None:
            self.previous_frontmost_pid = front_pid
        self.recent_launches = {
            pid: launched_at
            for pid, launched_at in self.recent_launches.items()
            if pid in codex_pids and now - launched_at < INITIAL_ACTIVATION_GRACE_SECONDS
        }

        if new_pids:
            self.recent_launches.update({pid: now for pid in new_pids})
            self.pending = PendingOpen(attempts=0, next_try_at=now)
            # A launch and its first foreground transition are one event.
            if front_pid in new_pids:
                self.recent_launches.pop(front_pid, None)
        elif activated:
            launched_at = self.recent_launches.pop(front_pid, None)
            came_from_pet_menu = (
                self.last_pet_foreground_at is not None
                and now - self.last_pet_foreground_at < INITIAL_ACTIVATION_GRACE_SECONDS
            )
            if not came_from_pet_menu and (
                launched_at is None or now - launched_at >= INITIAL_ACTIVATION_GRACE_SECONDS
            ):
                self.pending = PendingOpen(attempts=0, next_try_at=now)

        if not codex_pids:
            self.pending = None
        pending = self.pending
        if pending is None:
            return False
        if is_open_suppressed(codex_pids, self.visibility_path):
            self.pending = None
            return False
        if pending.waiting_for_pet and pet_pids:
            self.pending = None
            return False
        if now < pending.next_try_at:
            return False
        if pending.attempts >= MAX_OPEN_ATTEMPTS:
            self.pending = None
            return False

        # Check again at the actual open boundary in case Quit was recorded
        # during the timing checks above.
        if is_open_suppressed(codex_pids, self.visibility_path):
            self.pending = None
            return False
        opened = opener()
        pending.attempts += 1
        if opened:
            if pet_pids:
                self.pending = None
            else:
                pending.waiting_for_pet = True
                pending.next_try_at = now + PET_APPEAR_GRACE_SECONDS
        elif pending.attempts >= MAX_OPEN_ATTEMPTS:
            self.pending = None
        else:
            pending.waiting_for_pet = False
            pending.next_try_at = now + FAILED_OPEN_RETRY_SECONDS
        return True


def open_pet() -> bool:
    app = pet_app_path()
    if not app.is_dir():
        return False
    try:
        result = subprocess.run(
            ["/usr/bin/open", "-g", "-a", str(app)],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="在 Codex 桌面应用启动时打开额度宠物")
    parser.add_argument("--check", action="store_true", help="只检查 Codex 进程，不打开应用")
    parser.add_argument("--interval", type=float, default=2.0, help="检测间隔秒数")
    args = parser.parse_args(argv)
    if args.check:
        pids = desktop_pids()
        print("Codex desktop running" if pids else "Codex desktop not running")
        return 0 if pids else 1
    if args.interval < 0.5:
        parser.error("--interval must be at least 0.5 seconds")
    if not pet_app_path().is_dir():
        print("Codex Quota Pet.app is missing", file=sys.stderr)
        return 1

    watcher = CodexWatcher()
    while True:
        current, pet = running_app_pids()
        watcher.observe(current, pet, frontmost_pid(), time.monotonic())
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
