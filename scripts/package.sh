#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/dist/stremio-roku-sideload.zip"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
cd "$ROOT"
zip -qr "$OUT" manifest source components images
printf 'Created %s\n' "$OUT"
