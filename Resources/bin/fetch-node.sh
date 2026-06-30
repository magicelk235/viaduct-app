#!/bin/bash
# Download a self-contained official node binary to bundle inside the .app, so end
# users need NOT install Node themselves. Homebrew's node is a thin launcher linked
# against ~25 /opt/homebrew dylibs — useless off the build machine; nodejs.org ships
# a single statically-self-contained bin/node (links only /usr/lib + /System). That's
# the one we bundle.
#
# Run by the Xcode "Fetch Node" build phase (idempotent: skips if already present and
# the right version). The result, Resources/bin/node, is gitignored and produced at build.
set -euo pipefail

# Pin an LTS. Bump deliberately; the CLI needs >=18 (package.json engines).
NODE_VER="${VIADUCT_NODE_VERSION:-v20.18.1}"

DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$DIR/node"

# Match the build's arch so a universal build still ships a runnable node. xcodebuild
# sets $ARCHS during the phase; fall back to the host arch for a manual run.
host_arch="$(uname -m)"
arch="${ARCHS:-$host_arch}"
case "$arch" in
  *arm64*) NODE_ARCH="arm64" ;;
  *x86_64*) NODE_ARCH="x64" ;;
  *) echo "fetch-node: unsupported arch '$arch'"; exit 1 ;;
esac

# Skip the download if we already have the pinned version for this arch.
if [ -x "$DEST" ] && "$DEST" --version 2>/dev/null | grep -qx "$NODE_VER" \
   && [ -f "$DIR/.node-arch" ] && [ "$(cat "$DIR/.node-arch")" = "$NODE_ARCH" ]; then
  echo "fetch-node: $NODE_VER ($NODE_ARCH) already present — skipping."
  exit 0
fi

URL="https://nodejs.org/dist/${NODE_VER}/node-${NODE_VER}-darwin-${NODE_ARCH}.tar.gz"
echo "fetch-node: downloading $URL"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL "$URL" -o "$work/node.tar.gz"
# Extract just the binary — we don't ship npm/npx/headers, only the runtime.
tar xzf "$work/node.tar.gz" -C "$work" --strip-components=1 "node-${NODE_VER}-darwin-${NODE_ARCH}/bin/node"

mkdir -p "$DIR"
mv "$work/bin/node" "$DEST"
chmod 0755 "$DEST"
printf '%s' "$NODE_ARCH" > "$DIR/.node-arch"
echo "fetch-node: installed $("$DEST" --version) ($NODE_ARCH) → $DEST"
