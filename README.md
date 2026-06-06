# Chrome Extensions to Safari — App

A native macOS app (SwiftUI) that wraps the
[`chrome2safari`](https://www.npmjs.com/package/chrome2safari) command-line tool
in a graphical interface. Convert a Chrome extension into a Safari Web Extension
without touching the terminal.

## Features

- Pick a `.zip`, `.crx`, or unpacked extension folder and convert with one click.
- Every CLI flag exposed as a control: output dir, bundle id, app name,
  platforms (macOS / iOS / both), CI mode, temp-load, build toggle, install,
  signing (ad-hoc / auto-detected team / custom Team ID), shim, force, verbose.
- **Analyze** and **Doctor** buttons for report-only and toolchain checks.
- Live, scrolling output pane that streams the CLI's stdout/stderr.
- **Self-updating CLI**: the app pulls the latest `chrome2safari` from the npm
  registry and swaps it in — no rebuild of the app required.

## Requirements

- macOS 13+
- A full Xcode install (for `safari-web-extension-packager` and `xcodebuild`)
- Node.js 18+ on `PATH` (the app spawns `node` to run the bundled CLI)

## Build

```sh
# Option A: open the committed project
open Chrome2Safari.xcodeproj

# Option B: regenerate from project.yml (needs xcodegen)
xcodegen generate && open Chrome2Safari.xcodeproj
```

The CLI ships prebuilt under `Resources/cli/`. On launch the app checks npm for a
newer version and can update itself in place.

## License

MIT
