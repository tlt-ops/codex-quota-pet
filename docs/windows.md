# Windows guide

## Requirements

- Windows 10 or 11, x64.
- Codex CLI installed and signed in with the ChatGPT account used for Codex.
- For source use or local packaging, Node.js and npm.

The desktop app reads quota data from the local Codex CLI app-server interface. It does not inspect credentials, prompts, transcripts, or browser pages. If the CLI is not installed, signed in, or discoverable, quota values may be unavailable.

## Install

Download either the portable executable or per-user NSIS installer from GitHub Releases. The installer installs for the current user and does not need administrator rights. The portable executable can run without installation; keep it at the same path when Auto Open is configured.

## Controls

- The pet displays three quota rows. The rows show remaining percentage and window, reset date, and available reset count.
- Exactly two quick clicks open the radial menu. Three or more quick clicks launch a small character for each click. Select a launch mode in the radial menu.
- Press and hold the character to pinch it; release to launch. Bounce mode rebounds five times and fades away. Parabolic mode lets the character leave the screen. GPT Rain drops characters for ten seconds.
- Use the tray menu to show or hide the pet, refresh quota, start GPT Rain, change Auto Open, or quit. Sound test controls play the two supported Minecraft sounds and do not affect quota.

## Auto Open and visibility

Auto Open registers a current-user startup entry. At logon it starts a hidden watcher that polls for the Codex and ChatGPT desktop main processes. The watcher can open the pet when either app appears later, even if it was not running at logon. It does not need administrator rights.

Hide and Quit save a visibility choice so the watcher does not immediately reopen the pet for the same identified desktop process. The choice survives watcher restarts, process reactivation, and virtual desktop changes. A newly identified desktop process launch clears the saved choice. Select Show in the tray menu to restore the pet explicitly. Turning Auto Open off removes its startup entry; the pet can still be opened manually.

## Build from source

```powershell
npm ci
npm start
```

Create Windows packages with:

```powershell
npm run dist:win
```

The portable executable must remain at its configured path for startup registration to keep working. See `docs/TESTING.md` for current test and target acceptance status.
