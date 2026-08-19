#!/usr/bin/env bash
set -euo pipefail

# Pins the runner tag. Bump when the Dockerfile or baked agents change.
# Never tag :latest in gegenlesen.json.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="gegenlesen/opencode-runner:0.1.0"
OPENCODE_VERSION="${OPENCODE_VERSION:-1.1.25}"

arch="$(uname -m)"
if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
  platform="linux/arm64"
else
  platform="linux/amd64"
fi

exec docker build \
  --platform "$platform" \
  --build-arg "OPENCODE_VERSION=${OPENCODE_VERSION}" \
  -t "$IMAGE" \
  "$ROOT/docker/opencode-runner"
