#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-ghcr.io/pmdroid/gegenlesen:local}"

exec docker build -t "$IMAGE" "$ROOT"
