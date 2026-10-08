# Codex Quota Pet

A local desktop companion that displays quota windows reported by your signed-in Codex CLI account. The Windows edition targets Windows 10 and 11 on x64. A native macOS edition is maintained from the original Swift app source.

## Windows quick start

Download the portable `.exe` or per-user NSIS installer from GitHub Releases. No administrator rights are needed. Keep the portable executable in a stable location when Auto Open is enabled.

Install Codex CLI and sign in with the ChatGPT account you use for Codex. The app reads quota data through the CLI's local app-server interface. It does not read credentials, prompts, transcripts, or browser pages.

For a source checkout, install Node.js and run `npm ci` followed by `npm start`. To build Windows packages, run `npm run dist:win`.

See [the Windows guide](docs/windows.md) for controls and startup behavior, and [TESTING.md](docs/TESTING.md) for current evidence and acceptance status.

## Features

- Displays the quota windows returned by Codex, including remaining quota and reset time.
- Exactly two quick clicks open the radial menu. Three or more quick clicks launch characters. The mouse wheel changes launch mode.
- Pinching and releasing launches a character. Bounce mode rebounds five times and fades. GPT Rain lasts ten seconds.
- Shows three quota rows. Sound test controls play downloaded Minecraft sounds without changing quota.
- Auto Open starts a hidden watcher at user logon and opens the pet after it detects the Codex or ChatGPT desktop app. Hide and Quit intent persists for that process; a newly identified launch clears it. Use Show in the tray menu to restore the pet.

## macOS source

The original native Swift app and scripts are in [`native/macos`](native/macos/). The Windows port is a separate Electron implementation. See [TESTING.md](docs/TESTING.md) for the limits of available acceptance evidence.

## Assets and license

See [ASSETS.md](ASSETS.md) for artwork provenance and sharing scope. Minecraft audio is fetched at runtime, checked against Mojang's SHA-1 asset hashes, and not bundled. Refer to the [official Mojang asset index](https://piston-meta.mojang.com/v1/packages/32a06dd28a0a8a981f4a1dffbdb3931f3075ca6c/34.json) and [Minecraft Usage Guidelines](https://www.minecraft.net/en-us/usage-guidelines).

Code is licensed under the MIT License. Artwork terms are described separately in ASSETS.md.
