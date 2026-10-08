# Testing and acceptance status

This file records build and render evidence separately from acceptance on a user's machine. Windows CI has passed the checks below. Live account, startup and virtual desktop acceptance on a user's Windows 10/11 machine remains pending.

## Windows

Build and render checks on the Windows runner:

- [x] `npm ci` succeeds from a clean checkout.
- [x] `npm test` passes.
- [x] `npm run dist:win` produces the portable executable, per-user NSIS installer and ZIP.
- [x] Source and packaged executables start and render all three quota rows, the ten-button wheel and all 24 sprites with synthetic quota.
- [x] Pet right/bottom edges and full-screen effects bounds match the primary display exactly.

Pending acceptance on a user's Windows 10 or 11 x64 machine:

- [ ] Installed and portable builds start, show all three quota rows, and refresh through the local Codex CLI app-server.
- [ ] Two-click radial menu, three-click launch behavior, wheel mode selection, pinch launch, five rebounds and fade, and ten-second GPT Rain work.
- [ ] Auto Open starts a hidden watcher at user logon and detects either desktop app when launched later.
- [ ] Hide and Quit intent persists through reactivation, watcher restart, and virtual desktop changes; a new identified launch clears the saved intent; tray Show restores the pet.
- [ ] Sound tests fetch and hash-verify the sound files without changing quota values.
- [ ] No credentials or chat content are read.

### Windows CI results

2026-10-08, [GitHub Actions run 37712405578](https://github.com/tlt-ops/codex-quota-pet/actions/runs/37712405578), release `v1.0.0`, commit `669819b5493ecb55e47c8ffa4d9ebce30d687b6d`:

- Runner: Microsoft Windows Server 2025, image `windows-2025-vs2026` / `20260925.250.1`, Node.js 24.21.0, Electron 44.7.0.
- Clean `npm ci`, all 24 tests, source Electron render check, Windows x64 packaging and packaged executable render check passed.
- Both render reports have `ok: true`, `targetGeometryVerified: true`, `petAnchored: true`, `effectsOriginMatchesDisplay: true`, and an empty error list. On the 1024×768 display, the pet is `(624,368,400,400)` and effects are `(0,0,1024,768)`.
- Three text rows fit inside the bubble, all ten wheel buttons fit inside the window, and all 24 sprite images load. Pressing changes 8,492 character pixels and zero bubble pixels. The rain capture contains 120 synthetic particles.
- Actual packaged-app screenshots of the normal pet, wheel and rain were downloaded and visually inspected. Quota data in these captures is synthetic; no logged-in user account was used.
- [Release downloads](https://github.com/tlt-ops/codex-quota-pet/releases/tag/v1.0.0) include installer, portable executable, ZIP and SHA256SUMS.txt. All three published binaries were downloaded and their SHA-256 hashes matched. The ZIP contains the executable and application archive; the archive contains the renderer and both authorized artwork files.

The workflow artifacts `windows-smoke-evidence` contain source and packaged screenshots plus `report.json`. These checks start the executable from the packaged ZIP; they do not execute the NSIS installation flow or establish live account quota, startup registration, virtual desktops, DPI scaling or audible output on a user's machine.

### Local development results

2026-10-08, macOS local development check:

- `npm test`: 24 tests passed (quota RPC, process discovery fixtures, cross-process visibility lock, click sequences and particle motion).
- `npm run smoke`: passed actual Electron rendering with synthetic quota; all 24 sprites loaded, ten wheel buttons contained in the pet window, three quota rows inside the bubble. Pressing changed 8,224 character pixels and zero bubble pixels.
- Pet window met the main display right and bottom boundaries. The macOS Electron development effects window was constrained 34 points below the menu bar; this is recorded as a local platform difference and is not accepted as Windows geometry evidence. The Windows runner must pass the full display bounds check.
- Visual inspection confirmed the normal pet, ten-button wheel and effects captures. No live quota or account data appears in README screenshots.

## macOS

The `native/macos/` folder contains selected source, scripts, and synthetic fixtures from the original native app. Historical personal live-use logs and render-check outputs were intentionally excluded. On 2026-10-08, `python3 -m unittest discover -s native/macos/tests -q` passed all 43 tests in the staged native source. No new installed-macOS UI acceptance is asserted by this document.

Record future results here with date, OS version, command or manual steps, outcome, and relevant output or issue link. Automated source tests do not establish that UI behavior works on a real desktop.
