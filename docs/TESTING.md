# Testing and acceptance status

This file records evidence separately from claims about target-platform behavior. At repository preparation time, Windows user acceptance and Windows CI execution are pending. Do not describe either as passed without adding dated, reproducible evidence.

## Windows

Pending verification on Windows 10 or 11 x64:

- [ ] `npm ci` succeeds from a clean checkout.
- [ ] `npm test` passes.
- [ ] `npm run dist:win` produces the portable executable and per-user NSIS installer.
- [ ] Installed and portable builds start, show all three quota rows, and refresh through the local Codex CLI app-server.
- [ ] Two-click radial menu, three-click launch behavior, wheel mode selection, pinch launch, five rebounds and fade, and ten-second GPT Rain work.
- [ ] Auto Open starts a hidden watcher at user logon and detects either desktop app when launched later.
- [ ] Hide and Quit intent persists through reactivation, watcher restart, and virtual desktop changes; a new identified launch clears the saved intent; tray Show restores the pet.
- [ ] Sound tests fetch and hash-verify the sound files without changing quota values.
- [ ] No credentials or chat content are read.

### Results

Windows runner build and packaged-app verification are pending the first GitHub Actions run.

2026-10-08, macOS local development check:

- `npm test`: 24 tests passed (quota RPC, process discovery fixtures, cross-process visibility lock, click sequences and particle motion).
- `npm run smoke`: passed actual Electron rendering with synthetic quota; all 24 sprites loaded, ten wheel buttons contained in the pet window, three quota rows inside the bubble. Pressing changed 8,224 character pixels and zero bubble pixels.
- Pet window met the main display right and bottom boundaries. The macOS Electron development effects window was constrained 34 points below the menu bar; this is recorded as a local platform difference and is not accepted as Windows geometry evidence. The Windows runner must pass the full display bounds check.
- Visual inspection confirmed the normal pet, ten-button wheel and effects captures. No live quota or account data appears in README screenshots.

## macOS

The `native/macos/` folder contains selected source, scripts, and synthetic fixtures from the original native app. Historical personal live-use logs and render-check outputs were intentionally excluded. On 2026-10-08, `python3 -m unittest discover -s native/macos/tests -q` passed all 43 tests in the staged native source. No new installed-macOS UI acceptance is asserted by this document.

Record future results here with date, OS version, command or manual steps, outcome, and relevant output or issue link. Automated source tests do not establish that UI behavior works on a real desktop.
