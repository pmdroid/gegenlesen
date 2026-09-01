#!/usr/bin/env bash
set -euo pipefail

# Pins the runner tag. Bump when the Dockerfile or baked agents change.
# Never tag :latest in gegenlesen.json.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_IMAGE="gegenlesen/runner-base:0.1.0"
OPENCODE_IMAGE="gegenlesen/opencode-runner:0.1.0"
CLAUDE_IMAGE="gegenlesen/claude-runner:0.1.0"
CODEX_IMAGE="gegenlesen/codex-runner:0.1.0"
CURSOR_IMAGE="gegenlesen/cursor-runner:0.1.0"
GROK_IMAGE="gegenlesen/grok-runner:0.1.0"
OPENCODE_VERSION="${OPENCODE_VERSION:-1.1.25}"
CLAUDE_ACP_VERSION="${CLAUDE_ACP_VERSION:-0.72.0}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.257}"
CODEX_ACP_VERSION="${CODEX_ACP_VERSION:-1.8.0}"
GROK_VERSION="${GROK_VERSION:-1.0.17}"

arch="$(uname -m)"
if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
  platform="linux/arm64"
else
  platform="linux/amd64"
fi

build_base() {
  docker build \
    --platform "$platform" \
    -t "$BASE_IMAGE" \
    "$ROOT/docker/runner-base"
}

build_opencode() {
  docker build \
    --platform "$platform" \
    --build-arg "RUNNER_BASE=${BASE_IMAGE}" \
    --build-arg "OPENCODE_VERSION=${OPENCODE_VERSION}" \
    -t "$OPENCODE_IMAGE" \
    "$ROOT/docker/opencode-runner"
}

build_claude() {
  docker build \
    --platform "$platform" \
    --build-arg "RUNNER_BASE=${BASE_IMAGE}" \
    --build-arg "CLAUDE_ACP_VERSION=${CLAUDE_ACP_VERSION}" \
    --build-arg "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION}" \
    -t "$CLAUDE_IMAGE" \
    "$ROOT/docker/claude-runner"
}

build_codex() {
  docker build \
    --platform "$platform" \
    --build-arg "RUNNER_BASE=${BASE_IMAGE}" \
    --build-arg "CODEX_ACP_VERSION=${CODEX_ACP_VERSION}" \
    -t "$CODEX_IMAGE" \
    "$ROOT/docker/codex-runner"
}

build_cursor() {
  docker build \
    --platform "$platform" \
    --build-arg "RUNNER_BASE=${BASE_IMAGE}" \
    -t "$CURSOR_IMAGE" \
    "$ROOT/docker/cursor-runner"
}

build_grok() {
  docker build \
    --platform "$platform" \
    --build-arg "RUNNER_BASE=${BASE_IMAGE}" \
    --build-arg "GROK_VERSION=${GROK_VERSION}" \
    -t "$GROK_IMAGE" \
    "$ROOT/docker/grok-runner"
}

target="${1:-all}"
case "$target" in
  base) build_base ;;
  opencode) build_base && build_opencode ;;
  claude) build_base && build_claude ;;
  codex) build_base && build_codex ;;
  cursor) build_base && build_cursor ;;
  grok) build_base && build_grok ;;
  all)
    build_base
    build_opencode
    build_claude
    build_codex
    build_cursor
    build_grok
    ;;
  *)
    echo "usage: $0 [base|opencode|claude|codex|cursor|grok|all]" >&2
    exit 2
    ;;
esac
