#!/usr/bin/env bash
# Renders docs/mockups/*.html into docs/images/*.png (@2x) with headless Chrome.
# Usage: scripts/render_mockups.sh [page ...]   (default: all pages)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/docs/mockups"
OUT="$ROOT/docs/images"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

# page:width:height:langs[:theme]  (langs: "en ru" or "en"; theme: dark by default, "light" adds a -light suffix)
PAGES=(
  "popover:560:780:en ru"
  "popover:560:780:en ru:light"
  "details:560:780:en ru"
  "search:500:640:en ru"
  "colleagues:500:640:en ru"
  "create-meeting:1080:760:en ru"
  "menubar:1100:530:en ru"
  "settings:1080:700:en ru"
  "details:560:780:en ru:light"
  "search:500:640:en ru:light"
  "colleagues:500:640:en ru:light"
  "create-meeting:1080:760:en ru:light"
  "menubar:1100:530:en ru:light"
  "settings:1080:700:en ru:light"
  "hero:1280:640:en ru"
)

want() { [[ $# -eq 0 ]] && return 0; for p in "${SELECTED[@]}"; do [[ "$p" == "$1" ]] && return 0; done; return 1; }
SELECTED=("$@")

mkdir -p "$OUT"
for entry in "${PAGES[@]}"; do
  IFS=: read -r page width height langs theme <<<"$entry"
  if [[ ${#SELECTED[@]} -gt 0 ]] && ! want "$page"; then continue; fi
  for lang in $langs; do
    suffix="${theme:+-$theme}"
    target="$OUT/$page$suffix-$lang.png"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
      --default-background-color=00000000 --window-size="$width,$height" \
      --virtual-time-budget=2000 --screenshot="$target" \
      "file://$SRC/$page.html?lang=$lang${theme:+&theme=$theme}" >/dev/null 2>&1
    echo "rendered $target"
  done
done
