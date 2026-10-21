#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/stremio-roku-sideload.zip" "$ROOT/dist/stremio-companion.zip"
(
  cd "$ROOT"
  zip -qr "$ROOT/dist/stremio-roku-sideload.zip" manifest source components images
)
(
  cd "$ROOT"
  zip -qr "$ROOT/dist/stremio-companion.zip" companion     -x "companion/data/*" "companion/transcodes/*" "companion/node_modules/*"
)
printf 'Created %s\n' "$ROOT/dist/stremio-roku-sideload.zip"
printf 'Created %s\n' "$ROOT/dist/stremio-companion.zip"
