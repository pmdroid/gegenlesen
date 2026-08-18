#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if command -v docker >/dev/null 2>&1; then
  docker network inspect meister-egress >/dev/null 2>&1 \
    || docker network create meister-egress
fi

swift run MeisterAPI serve --data-dir ./var --bind 127.0.0.1 --port 8080 &
api_pid=$!
fe_pid=""

cleanup() {
  kill "$api_pid" ${fe_pid:+"$fe_pid"} 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$root/frontend"
if [[ ! -d node_modules ]]; then
  npm install
fi
npm run dev &
fe_pid=$!

wait
