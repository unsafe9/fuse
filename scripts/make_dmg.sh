#!/usr/bin/env bash
# Build a compressed DMG containing Fuse.app and an /Applications symlink.
# Usage: make_dmg.sh <Fuse.app> <output.dmg>
set -euo pipefail

APP="${1:?usage: make_dmg.sh <Fuse.app> <output.dmg>}"
OUT="${2:?usage: make_dmg.sh <Fuse.app> <output.dmg>}"

if [[ ! -d "$APP" ]]; then
    echo "make_dmg.sh: app bundle not found: $APP" >&2
    exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

rm -f "$OUT"
mkdir -p "$(dirname "$OUT")"

hdiutil create \
    -volname "Fuse" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    "$OUT"

echo "make_dmg.sh: wrote $OUT"
