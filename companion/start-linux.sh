#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")"
node --version >/dev/null 2>&1 || { echo "Node.js 20+ é obrigatório."; exit 1; }
exec node server.mjs
