#!/bin/zsh
set -eu
ICON_ROOT="${0:A:h}"
ICON_WORK=$(mktemp -d "${TMPDIR:-/tmp}/uvz-icon.XXXXXX")
trap 'rm -rf "$ICON_WORK"' EXIT
mkdir -p "$ICON_WORK/AppIcon.iconset"
for ICON_SIZE in 16 32 128 256 512; do
  /usr/bin/sips -z "$ICON_SIZE" "$ICON_SIZE" "$ICON_ROOT/AppIcon.png" --out "$ICON_WORK/AppIcon.iconset/icon_${ICON_SIZE}x${ICON_SIZE}.png" >/dev/null
  ICON_DOUBLE=$((ICON_SIZE * 2))
  /usr/bin/sips -z "$ICON_DOUBLE" "$ICON_DOUBLE" "$ICON_ROOT/AppIcon.png" --out "$ICON_WORK/AppIcon.iconset/icon_${ICON_SIZE}x${ICON_SIZE}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$ICON_ROOT/AppIcon.icns"
