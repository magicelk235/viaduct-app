# Viaduct — App

A native macOS app (SwiftUI) that wraps the
[`@magicelk235/viaduct`](https://www.npmjs.com/package/@magicelk235/viaduct) command-line tool
in a graphical interface. Convert a Chrome extension into a Safari Web Extension
without touching the terminal.

## Features

- Pick a `.zip`, `.crx`, or unpacked extension folder and convert with one click.
- Every CLI flag exposed as a control: output dir, bundle id, app name,
  platforms (macOS / iOS / both), CI mode, temp-load, build toggle, install,
  signing (ad-hoc / auto-detected team / custom Team ID), shim, force, verbose.
- **Analyze** and **Doctor** buttons for report-only and toolchain checks.
- Live, scrolling output pane that streams the CLI's stdout/stderr.
- **Install straight from the Chrome Web Store** via the `viaduct://install?id=<ID>&name=<NAME>`
  URL scheme. The app downloads the `.crx` and converts it. Pass `name` so the
  converted app is named after the store listing, not its random-looking ID.
  (Names that use Chrome's `__MSG_` i18n keys are resolved from `_locales` too.)
- **Auto-renew** (Settings → Signing, on by default): free Apple accounts sign
  extensions for ~7 days, after which Safari drops them. The app rebuilds and
  re-signs installed extensions before that lapses, using the Apple identity it
  auto-detects from Xcode — so they never silently disappear.
- **Self-updating CLI**: on launch the app checks npm and, if a newer
  `@magicelk235/viaduct` exists, installs it automatically — no button, no app rebuild.

## Install

```sh
brew tap magicelk235/viaduct
brew install --cask viaduct
```

## Requirements

- macOS 13+
- A full Xcode install (for `safari-web-extension-packager` and `xcodebuild`)
- Node.js 18+ on `PATH` (the app spawns `node` to run the bundled CLI)

> **Not sandboxed.** The app shells out to `node`, `xcodebuild`, `lsregister`,
> and `open`, which the macOS App Sandbox forbids — so it ships unsandboxed and
> is **not** a Mac App Store app. Distribute as a notarized direct download.

## Build

```sh
# Option A: open the committed project
open Viaduct.xcodeproj

# Option B: regenerate from project.yml (needs xcodegen)
xcodegen generate && open Viaduct.xcodeproj
```

The CLI ships prebuilt under `Resources/cli/`. On launch the app checks npm for a
newer version and can update itself in place.

## License

MIT
