#!/bin/bash
# Build a distributable Viaduct.dmg: dark frosted background, the app and an
# /Applications symlink floating above the Viaduct arches that bridge them.
# Run build.sh first (or pass an existing .app). Native hdiutil + AppleScript,
# no third-party tooling. Run from anywhere — paths resolve to the repo root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (this script lives in dmg/)
cd "$ROOT"                                  # so the bg renderer finds its assets
APP="${1:-$ROOT/build/Build/Products/Release/Viaduct.app}"
[ -d "$APP" ] || { echo "FAILED: app not found at $APP (run ./build.sh first)"; exit 1; }

VOL="Install Viaduct"
OUT="$ROOT/Viaduct.dmg"
BG="$ROOT/dmg/dmg-bg.png"
STAGE="$(mktemp -d)"
RW="$(mktemp -u).dmg"
trap 'hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true; rm -rf "$STAGE" "$RW"' EXIT

echo "==> Rendering background"
swift "$ROOT/dmg/make-dmg-bg.swift" >/dev/null

echo "==> Staging"
ditto "$APP" "$STAGE/Viaduct.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$BG" "$STAGE/.background/bg.png"

echo "==> Creating writable image"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ \
  -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -mountpoint "/Volumes/$VOL" -nobrowse >/dev/null

echo "==> Laying out window"
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 820, 540}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set background picture of theViewOptions to file ".background:bg.png"
    set position of item "Viaduct.app" of container window to {150, 130}
    set position of item "Applications" of container window to {470, 130}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

echo "==> Compressing"
sync
hdiutil detach "/Volumes/$VOL" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null

echo "==> Done: $OUT"
