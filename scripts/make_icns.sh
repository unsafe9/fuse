#!/usr/bin/env bash
# Convert a 1024x1024 source PNG into an AppIcon.icns.
# Usage: make_icns.sh <source.png> <output.icns>
set -euo pipefail

SRC="${1:?usage: make_icns.sh <source.png> <output.icns>}"
OUT="${2:?usage: make_icns.sh <source.png> <output.icns>}"

if [[ ! -f "$SRC" ]]; then
    echo "make_icns.sh: source icon not found: $SRC" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# size@1x  size@2x
gen() {
    local size="$1" name="$2"
    sips -z "$size" "$size" "$SRC" --out "$ICONSET/$name" >/dev/null
}

gen 16   "icon_16x16.png"
gen 32   "icon_16x16@2x.png"
gen 32   "icon_32x32.png"
gen 64   "icon_32x32@2x.png"
gen 128  "icon_128x128.png"
gen 256  "icon_128x128@2x.png"
gen 256  "icon_256x256.png"
gen 512  "icon_256x256@2x.png"
gen 512  "icon_512x512.png"
gen 1024 "icon_512x512@2x.png"

mkdir -p "$(dirname "$OUT")"
iconutil --convert icns "$ICONSET" --output "$OUT"

echo "make_icns.sh: wrote $OUT"
