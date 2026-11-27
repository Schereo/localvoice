#!/bin/bash

# Download the pinned Sparkle release (the in-app updater) into build/sparkle and
# print where it is. The archive is checked against a pinned SHA-256 on every run
# and unpacked afresh; only the download is reused.
#
#   ./scripts/fetch-sparkle.sh        ->  Sparkle: <dir>   (holds Sparkle.framework and bin/)
#
# The app build embeds <dir>/Sparkle.framework; the release workflow runs
# <dir>/bin/generate_appcast to sign updates and build the delta patches.

set -euo pipefail

SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$ROOT/build/sparkle"
DEST="$CACHE/$SPARKLE_VERSION"
ARCHIVE="$CACHE/Sparkle-$SPARKLE_VERSION.tar.xz"

verified() {
  [[ -f "$ARCHIVE" ]] && [[ "$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)" == "$SPARKLE_SHA256" ]]
}

mkdir -p "$CACHE"
if ! verified; then
  rm -rf "$DEST" "$ARCHIVE"
  curl --fail --silent --show-error --location --retry 3 --max-time 120 \
    --max-filesize $((64 * 1024 * 1024)) --output "$ARCHIVE.part" "$SPARKLE_URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
  if ! verified; then
    rm -f "$ARCHIVE"
    echo "Error: Sparkle $SPARKLE_VERSION does not match its pinned checksum." >&2
    exit 1
  fi
fi

# Always unpacked afresh from the verified archive (a second or so): the release
# job runs bin/generate_appcast with the update key, and a tree left in build/
# could come from anywhere. The marker only tells check.sh that it is there.
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$ARCHIVE" -C "$DEST" Sparkle.framework bin LICENSE
touch "$DEST/.unpacked"

echo "Sparkle: $DEST"
