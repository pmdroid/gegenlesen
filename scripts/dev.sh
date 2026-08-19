#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=toolchain.sh
. "$root/scripts/toolchain.sh"
meister_sync_build_dir "$root"
cd "$root"

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
