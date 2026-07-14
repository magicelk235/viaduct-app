#!/bin/bash
# Build a DISTRIBUTABLE Viaduct.app + notarized Viaduct.dmg for public download.
#
# Unlike build.sh (Apple Development, this-Mac-only), this signs with the
# Developer ID Application cert + hardened runtime + secure timestamp, then
# notarizes and staples the DMG so it opens cleanly on any Mac (no Gatekeeper
# warning). Requires: `xcrun notarytool store-credentials viaduct-notary ...`
# has been run once (stores Apple ID + team + app-specific password in keychain).
#
# Usage: ./release.sh          # build, sign, dmg, notarize, staple
#        ./release.sh --no-notarize   # stop after building the signed dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REL="$ROOT/build/Build/Products/Release"
# Sign in /tmp, NOT in the repo: the repo is iCloud-synced and sync restamps
# com.apple.FinderInfo mid-sign, which codesign rejects ("detritus not allowed").
# /tmp is not synced, so signing is a clean one-shot — no detritus race.
WORK="/private/tmp/viaduct-release"
APP="$WORK/Viaduct.app"
APPEX="$APP/Contents/PlugIns/ViaductExtension.appex"
EXT_ENT="$ROOT/Extension/ViaductExtension.entitlements"
APP_ENT="$ROOT/Viaduct.entitlements"
KEYCHAIN_PROFILE="viaduct-notary"
NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

# Developer ID Application identity — the one distributable outside the App Store.
SIGN_ID="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | grep -oE '[A-F0-9]{40}')"
[ -n "$SIGN_ID" ] || { echo "FAILED: no Developer ID Application identity found"; exit 1; }
echo "==> Signing identity: $SIGN_ID"

echo "==> Building (unsigned)"
rm -rf "$REL"
xcodebuild -project "$ROOT/Viaduct.xcodeproj" -scheme Viaduct \
  -configuration Release -derivedDataPath "$ROOT/build" \
  CODE_SIGNING_ALLOWED=NO >/dev/null

# Copy out of the iCloud-synced repo to /tmp, then sign there (see WORK note above).
echo "==> Staging to $WORK for signing"
rm -rf "$WORK" && mkdir -p "$WORK"
ditto "$REL/Viaduct.app" "$APP"

# Sign inside-out (extension first, then app). --timestamp (secure, not =none) and
# --options runtime are MANDATORY for notarization.
echo "==> Signing with Developer ID"
xattr -cr "$APP"
codesign --force --sign "$SIGN_ID" --timestamp --options runtime \
  --entitlements "$EXT_ENT" "$APPEX"
codesign --force --sign "$SIGN_ID" --timestamp --options runtime \
  --entitlements "$APP_ENT" "$APP"

# Gatekeeper assessment before we even notarize — catches signing mistakes early.
echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building DMG"
"$ROOT/dmg/make-dmg.sh" "$APP"
OUT="$ROOT/Viaduct.dmg"

# Delete both loose app copies (unsigned build product + signed staging copy):
# duplicate bundles with the installed app's bundle id can steal the Safari
# extension binding from /Applications and wedge the store-page progress card.
rm -rf "$REL/Viaduct.app" "$WORK"

if [ "$NOTARIZE" = 0 ]; then
  echo "==> Done (unnotarized): $OUT"
  echo "    Users WILL hit Gatekeeper warnings. Re-run without --no-notarize to ship."
  exit 0
fi

# Notarize the DMG itself (staple works on the .dmg; users mount and drag).
echo "==> Notarizing (submits to Apple, waits for result — can take a few min)"
xcrun notarytool submit "$OUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "==> Stapling ticket"
xcrun stapler staple "$OUT"
xcrun stapler validate "$OUT"

echo "==> Done: $OUT (signed + notarized + stapled — ships clean on any Mac)"
