#!/usr/bin/env python3
"""Stop and remove the per-user CodexQuotaPet launch watcher."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path


LABEL = "com.codexquotapet.watcher"
PLIST_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "CodexQuotaPet"
INSTALLED_WATCHER = SUPPORT_DIR / "watch_codex.py"
INSTALLED_APP = SUPPORT_DIR / "Codex Quota Pet.app"


def main() -> int:
    if sys.platform != "darwin":
        print("This uninstaller requires macOS", file=sys.stderr)
        return 1
    domain = f"gui/{os.getuid()}"
    subprocess.run(["/bin/launchctl", "bootout", domain, str(PLIST_PATH)], capture_output=True)
    try:
        PLIST_PATH.unlink(missing_ok=True)
        INSTALLED_WATCHER.unlink(missing_ok=True)
        if INSTALLED_APP.is_dir():
            shutil.rmtree(INSTALLED_APP)
    except OSError:
        print("Could not remove installed watcher or app", file=sys.stderr)
        return 1
    print("Removed LaunchAgent, watcher, and installed app; quota snapshot remains")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
