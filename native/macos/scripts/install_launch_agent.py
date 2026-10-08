#!/usr/bin/env python3
"""Install and activate the per-user CodexQuotaPet launch watcher."""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


LABEL = "com.codexquotapet.watcher"
PLIST_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
DEFAULT_WATCHER = Path(__file__).resolve().parent / "watch_codex.py"
DEFAULT_APP = DEFAULT_WATCHER.parent.parent / "app" / "Codex Quota Pet.app"
SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "CodexQuotaPet"
INSTALLED_WATCHER = SUPPORT_DIR / "watch_codex.py"
INSTALLED_APP = SUPPORT_DIR / "Codex Quota Pet.app"


def _same_path(source: Path, destination: Path) -> bool:
    return source.resolve() == destination.resolve()


def _copy_app(source: Path, destination: Path) -> None:
    if _same_path(source, destination):
        return
    stage_dir = Path(tempfile.mkdtemp(prefix=".pet-stage-", dir=destination.parent))
    backup = destination.parent / f".pet-backup-{uuid.uuid4().hex}"
    try:
        staged_app = stage_dir / destination.name
        shutil.copytree(source, staged_app, symlinks=True)
        if destination.exists():
            destination.rename(backup)
        try:
            staged_app.rename(destination)
        except OSError:
            if backup.exists():
                backup.rename(destination)
            raise
        if backup.exists():
            shutil.rmtree(backup)
    finally:
        shutil.rmtree(stage_dir, ignore_errors=True)


def _copy_watcher(source: Path, destination: Path) -> None:
    if _same_path(source, destination):
        return
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".watcher-", delete=False) as temp:
            temp_name = temp.name
            os.fchmod(temp.fileno(), 0o644)
            temp.write(source.read_bytes())
            temp.flush()
            os.fsync(temp.fileno())
        os.replace(temp_name, destination)
        temp_name = None
    finally:
        if temp_name is not None:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="安装 Codex 额度宠物的自动打开服务")
    parser.add_argument("--app", type=Path, default=DEFAULT_APP, help="源 .app bundle 路径")
    parser.add_argument("--watcher", type=Path, default=DEFAULT_WATCHER, help="源 watch_codex.py 路径")
    args = parser.parse_args(argv)
    if sys.platform != "darwin":
        print("This installer requires macOS", file=sys.stderr)
        return 1
    source_app = args.app.expanduser().resolve()
    source_watcher = args.watcher.expanduser().resolve()
    if not source_watcher.is_file() or not (source_app / "Contents" / "Info.plist").is_file():
        print("Watcher or app bundle is missing", file=sys.stderr)
        return 1

    SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    domain = f"gui/{os.getuid()}"
    # Stop the old watcher before replacing its executable and app bundle.
    subprocess.run(["/bin/launchctl", "bootout", domain, str(PLIST_PATH)], capture_output=True)
    try:
        _copy_app(source_app, INSTALLED_APP)
        _copy_watcher(source_watcher, INSTALLED_WATCHER)
    except OSError:
        print("Could not install app and watcher", file=sys.stderr)
        return 1

    plist = {
        "Label": LABEL,
        "ProgramArguments": ["/usr/bin/python3", str(INSTALLED_WATCHER)],
        "RunAtLoad": True,
        "KeepAlive": True,
        "StandardOutPath": "/dev/null",
        "StandardErrorPath": "/dev/null",
    }
    PLIST_PATH.parent.mkdir(parents=True, exist_ok=True)
    content = plistlib.dumps(plist, fmt=plistlib.FMT_XML)
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=PLIST_PATH.parent, prefix=".codexquotapet-", delete=False) as temp:
            temp_name = temp.name
            os.fchmod(temp.fileno(), 0o644)
            temp.write(content)
            temp.flush()
            os.fsync(temp.fileno())
        os.replace(temp_name, PLIST_PATH)
        temp_name = None
    finally:
        if temp_name is not None:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass

    activated = subprocess.run(
        ["/bin/launchctl", "bootstrap", domain, str(PLIST_PATH)],
        capture_output=True,
        text=True,
    )
    if activated.returncode != 0:
        print("LaunchAgent file installed, but activation failed", file=sys.stderr)
        return 1
    print(f"Installed {INSTALLED_APP} and activated {PLIST_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
