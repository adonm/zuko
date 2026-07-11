#!/bin/sh
# Regenerate every shipped Zuko logo/icon from the canonical 64 px pixel-art
# source at zuko-logo.png. ImageMagick 7 (`magick`) is required.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
SOURCE="$ROOT/zuko-logo.png"
CORNER_RADIUS=7

if ! command -v magick >/dev/null 2>&1; then
  echo "generate-icons: ImageMagick 7 (magick) is required" >&2
  exit 1
fi
if [ ! -f "$SOURCE" ]; then
  echo "generate-icons: missing canonical source: $SOURCE" >&2
  exit 1
fi
if [ "$(magick identify -format '%wx%h' "$SOURCE")" != "64x64" ]; then
  echo "generate-icons: canonical source must be exactly 64x64" >&2
  exit 1
fi
if [ "$(magick identify -format '%[opaque]' "$SOURCE")" != "True" ]; then
  echo "generate-icons: canonical source must be opaque" >&2
  exit 1
fi

# Standalone icons keep a small transparent radius instead of exposing the
# source canvas's hard square corners. Work at the canonical resolution so
# point sampling preserves the same pixel-art silhouette at every output size.
mkdir -p "$ROOT/.tmp"
ROUNDED_SOURCE=$(mktemp "$ROOT/.tmp/zuko-logo-rounded.XXXXXX.png")
VECTOR_SOURCE=$(mktemp "$ROOT/.tmp/zuko-logo-vector.XXXXXX.svg")
trap 'rm -f "$ROUNDED_SOURCE" "$VECTOR_SOURCE"' EXIT HUP INT TERM
magick "$SOURCE" -alpha set \
  \( -size 64x64 xc:none -fill white \
     -draw "roundrectangle 0,0 63,63 $CORNER_RADIUS,$CORNER_RADIUS" \) \
  -compose DstIn -composite -strip "$ROUNDED_SOURCE"

# Convert same-color horizontal pixel runs to real SVG geometry. The rounded
# clip stays vector-native, while crispEdges preserves the intentional grid.
magick "$SOURCE" -depth 8 txt:- | \
  awk -v radius="$CORNER_RADIUS" -f "$SCRIPT_DIR/pixel-svg.awk" > "$VECTOR_SOURCE"
cp "$VECTOR_SOURCE" "$ROOT/zuko-logo.svg"

resize_pixel_art() {
  size=$1
  destination=$2
  mkdir -p "$(dirname -- "$destination")"
  magick "$ROUNDED_SOURCE" -filter point -resize "${size}x${size}!" -strip "$destination"
}

# Flutter Apple runners use the same opaque source and let each OS apply its
# own platform mask. Keep the generated template filenames stable so Xcode's
# committed Contents.json files remain untouched.
for spec in \
  Icon-App-20x20@1x.png:20 Icon-App-20x20@2x.png:40 Icon-App-20x20@3x.png:60 \
  Icon-App-29x29@1x.png:29 Icon-App-29x29@2x.png:58 Icon-App-29x29@3x.png:87 \
  Icon-App-40x40@1x.png:40 Icon-App-40x40@2x.png:80 Icon-App-40x40@3x.png:120 \
  Icon-App-60x60@2x.png:120 Icon-App-60x60@3x.png:180 \
  Icon-App-76x76@1x.png:76 Icon-App-76x76@2x.png:152 \
  Icon-App-83.5x83.5@2x.png:167 Icon-App-1024x1024@1x.png:1024; do
  name=${spec%%:*}
  size=${spec#*:}
  magick "$SOURCE" -filter point -resize "${size}x${size}!" -strip \
    "$ROOT/flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset/$name"
done

for size in 16 32 64 128 256 512 1024; do
  magick "$SOURCE" -filter point -resize "${size}x${size}!" -strip \
    "$ROOT/flutter/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png"
done

# Flutter Android launcher icons retain the existing application identity.
for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  density=${spec%%:*}
  canvas=${spec#*:}
  directory="$ROOT/flutter/android/app/src/main/res/mipmap-$density"
  mkdir -p "$directory"
  resize_pixel_art "$canvas" "$directory/ic_launcher.png"
done

# Shared Flutter and Windows package icons.
resize_pixel_art 256 "$ROOT/flutter/assets/zuko-logo.png"
magick "$ROUNDED_SOURCE" -filter point -define icon:auto-resize=256,128,64,48,32,16 \
  "$ROOT/flutter/windows/runner/resources/app_icon.ico"

# Browser/docs copies are generated rather than hand-edited. Keep PNG fallbacks
# while using the true vector form on surfaces that support SVG.
resize_pixel_art 192 "$ROOT/flutter/web/icons/Icon-192.png"
resize_pixel_art 512 "$ROOT/flutter/web/icons/Icon-512.png"
resize_pixel_art 192 "$ROOT/flutter/web/icons/Icon-maskable-192.png"
resize_pixel_art 512 "$ROOT/flutter/web/icons/Icon-maskable-512.png"
resize_pixel_art 64 "$ROOT/flutter/web/favicon.png"
resize_pixel_art 256 "$ROOT/docs/zuko-logo.png"
resize_pixel_art 64 "$ROOT/theme/favicon.png"
cp "$VECTOR_SOURCE" "$ROOT/docs/zuko-logo.svg"
cp "$VECTOR_SOURCE" "$ROOT/theme/favicon.svg"

echo "generated Zuko icons from zuko-logo.png"
