#!/usr/bin/env bash
set -euo pipefail

# Local tag. CI publishes the same image as ghcr.io/pmdroid/gegenlesen:scanner-main.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${GEGENLESEN_SCANNER_IMAGE:-gegenlesen/scanner:0.1.0}"

arch="$(uname -m)"
if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
  platform="linux/arm64"
else
  platform="linux/amd64"
fi

exec docker build \
  --platform "$platform" \
  -t "$IMAGE" \
  "$ROOT/docker/scanner"
