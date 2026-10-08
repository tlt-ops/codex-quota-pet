# Contributing

Keep changes focused and preserve the separate Windows Electron and macOS Swift implementations. Do not add credentials, quota snapshots from personal accounts, chat content, or personal live-use records.

For Windows source changes, install dependencies with `npm ci`. Run `npm test` for the test suite and `npm run dist:win` to produce Windows packages. Windows behavior that depends on the real Codex or ChatGPT desktop process must be described as unverified until checked on Windows.

For macOS source changes, review the code and tests under `native/macos/`. The source is retained from the original native app; do not replace its behavior with assumptions based on the Windows port.

Keep documentation evidence-based: distinguish automated tests and package builds from actual use on the target operating system. Do not claim user acceptance based on local checks alone. Preserve asset provenance and the separate artwork terms in `ASSETS.md`.
