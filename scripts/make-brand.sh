#!/usr/bin/env bash
# Blit's brand images (scripts/brand/blit-brand.html), rendered with WebKit
# (scripts/brand/render.swift) into site/brand/: blit-product-1600x1200.png (Lemon Squeezy's
# product image), blit-card-1200x630.png (the site's link preview, og:image; launch/media keeps a
# copy for Product Hunt and the X thread) and blit-github-1280x640.png (the repository's social
# preview: GitHub › Settings › General), and Product Hunt's images (launch/product-hunt.md) into
# launch/product-hunt/: the first from blit-brand.html#ph, the rest from scripts/brand/blit-ph.html.
# Run it after changing either page. As Rune's scripts/make-brand.sh.
#
#   scripts/make-brand.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

mkdir -p site/brand build
swiftc -O -o build/render-page scripts/brand/render.swift
render() {   # render <fragment> <width> <height> <output>
  build/render-page "scripts/brand/blit-brand.html#$1" "$2" "$3" "$4"   # at 2×, averaged down to exactly this size
  echo "==> $4 ($(sips -g pixelWidth -g pixelHeight "$4" | awk '/pixel/ {print $2}' | paste -sd x -))"
}
render product 1600 1200 site/brand/blit-product-1600x1200.png
render card 1200 630 site/brand/blit-card-1200x630.png
cp site/brand/blit-card-1200x630.png launch/media/blit-card-1200x630.png
render github 1280 640 site/brand/blit-github-1280x640.png
# Product Hunt: the gallery at 1270×760 (the first is also the preview when the page is shared),
# the thumbnail at 240×240.
mkdir -p launch/product-hunt
renderph() {   # renderph <fragment> <width> <height> <output>
  build/render-page "scripts/brand/blit-ph.html#$1" "$2" "$3" "$4"
  echo "==> $4 ($(sips -g pixelWidth -g pixelHeight "$4" | awk '/pixel/ {print $2}' | paste -sd x -))"
}
render ph 1270 760 launch/product-hunt/1-blit-1270x760.png
renderph verified 1270 760 launch/product-hunt/2-verified-1270x760.png
renderph speed 1270 760 launch/product-hunt/3-speed-1270x760.png
renderph watch 1270 760 launch/product-hunt/4-new-downloads-1270x760.png
renderph thumb 240 240 launch/product-hunt/thumbnail-240x240.png
