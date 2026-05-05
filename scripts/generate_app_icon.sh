#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_SVG="$ROOT_DIR/OWAWidget/Resources/AppIcon/app-icon-master.svg"
ICONSET_DIR="$ROOT_DIR/OWAWidget/Resources/AppIcon.iconset"
OUT_ICNS="$ROOT_DIR/OWAWidget/Resources/AppIcon.icns"
TMP_PNG="$ICONSET_DIR/icon_1024x1024.png"

if [[ ! -f "$SRC_SVG" ]]; then
  echo "Missing source icon: $SRC_SVG" >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR"

# Render SVG master into 1024px PNG.
sips -s format png "$SRC_SVG" --out "$TMP_PNG" >/dev/null
sips -z 1024 1024 "$TMP_PNG" --out "$TMP_PNG" >/dev/null

declare -a SIZES=(
  "16"
  "32"
  "128"
  "256"
  "512"
)

for size in "${SIZES[@]}"; do
  sips -z "$size" "$size" "$TMP_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$TMP_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

for required in \
  "icon_16x16.png" \
  "icon_16x16@2x.png" \
  "icon_32x32.png" \
  "icon_32x32@2x.png" \
  "icon_128x128.png" \
  "icon_128x128@2x.png" \
  "icon_256x256.png" \
  "icon_256x256@2x.png" \
  "icon_512x512.png" \
  "icon_512x512@2x.png"; do
  if [[ ! -f "$ICONSET_DIR/$required" ]]; then
    echo "Missing generated file: $ICONSET_DIR/$required" >&2
    exit 1
  fi
done

iconutil -c icns "$ICONSET_DIR" -o "$OUT_ICNS"

if [[ ! -f "$OUT_ICNS" ]]; then
  echo "Failed to generate $OUT_ICNS" >&2
  exit 1
fi

echo "Generated: $OUT_ICNS"
