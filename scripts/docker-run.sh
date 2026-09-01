#!/usr/bin/env bash
# Run the gegenlesen API container with Docker socket, data/config dirs, and
# host agent credential folders mounted for ACP Setup auth + model listing.
#
# Usage:
#   ./scripts/docker-run.sh              # Mac / Docker Desktop (port publish)
#   ./scripts/docker-run.sh --host-network   # Linux (--network host)
#   ./scripts/docker-run.sh --rm         # foreground, remove on exit
#
# Env: GEGENLESEN_DATA_DIR, GEGENLESEN_CONFIG_DIR, GEGENLESEN_IMAGE,
#      GEGENLESEN_PUBLISH_BIND (default 0.0.0.0), GEGENLESEN_PORT (8080),
#      GEGENLESEN_HOST_HOME_MOUNT (default /host-home),
#      plus provider keys (ANTHROPIC_API_KEY, CURSOR_API_KEY, …) forwarded when set.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA="${GEGENLESEN_DATA_DIR:-${HOME}/gegenlesen-data}"
CONFIG="${GEGENLESEN_CONFIG_DIR:-${HOME}/gegenlesen-config}"
HOST_HOME="${GEGENLESEN_HOST_HOME_MOUNT:-/host-home}"
IMAGE="${GEGENLESEN_IMAGE:-ghcr.io/pmdroid/gegenlesen:0.1.15}"
PUBLISH_BIND="${GEGENLESEN_PUBLISH_BIND:-0.0.0.0}"
PORT="${GEGENLESEN_PORT:-8080}"
NAME="${GEGENLESEN_CONTAINER_NAME:-gegenlesen}"
RUNNER_TAG="${GEGENLESEN_RUNNER_TAG:-0.1.15}"
REGISTRY="${GEGENLESEN_REGISTRY:-ghcr.io/pmdroid/gegenlesen}"

HOST_NETWORK=0
RM=0
DETACH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host-network) HOST_NETWORK=1; shift ;;
    --rm) RM=1; DETACH=0; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$DATA" "$CONFIG"

mount_if() {
  local src="$1" dest="$2" mode="${3:-ro}"
  if [[ -e "$src" ]]; then
    MOUNTS+=(-v "${src}:${dest}:${mode}")
  fi
}

MOUNTS=(
  -v /var/run/docker.sock:/var/run/docker.sock
  -v "${DATA}:${DATA}"
  -v "${CONFIG}:/app/config"
)

mount_if "${HOME}/.claude" "${HOST_HOME}/.claude"
mount_if "${HOME}/.codex" "${HOST_HOME}/.codex"
mount_if "${HOME}/.cursor" "${HOST_HOME}/.cursor"
mount_if "${HOME}/.grok" "${HOST_HOME}/.grok"
mount_if "${HOME}/.config/cursor" "${HOST_HOME}/.config/cursor"
mount_if "${HOME}/.local/bin" "${HOST_HOME}/.local/bin"

ENV_ARGS=(
  -e "GEGENLESEN_DATA_DIR=${DATA}"
  -e "GEGENLESEN_HOST_HOME=${HOST_HOME}"
  -e "GEGENLESEN_BIND=0.0.0.0"
  -e "GEGENLESEN_PORT=${PORT}"
  -e "GEGENLESEN_ALLOW_REMOTE=1"
  -e "GEGENLESEN_OPENCODE_IMAGE=${REGISTRY}:runner-${RUNNER_TAG}"
  -e "GEGENLESEN_CLAUDE_RUNNER_IMAGE=${REGISTRY}:claude-runner-${RUNNER_TAG}"
  -e "GEGENLESEN_CODEX_RUNNER_IMAGE=${REGISTRY}:codex-runner-${RUNNER_TAG}"
  -e "GEGENLESEN_CURSOR_RUNNER_IMAGE=${REGISTRY}:cursor-runner-${RUNNER_TAG}"
  -e "GEGENLESEN_GROK_RUNNER_IMAGE=${REGISTRY}:grok-runner-${RUNNER_TAG}"
  -e "GEGENLESEN_SCANNER_IMAGE=${REGISTRY}:scanner-${RUNNER_TAG}"
)

for key in \
  ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY CODEX_API_KEY \
  CURSOR_API_KEY CURSOR_AUTH_TOKEN XAI_API_KEY GROK_API_KEY
do
  if [[ -n "${!key:-}" ]]; then
    ENV_ARGS+=(-e "${key}=${!key}")
  fi
done

NETWORK_ARGS=()
if [[ "$HOST_NETWORK" -eq 1 ]]; then
  NETWORK_ARGS=(--network host)
else
  NETWORK_ARGS=(-p "${PUBLISH_BIND}:${PORT}:${PORT}")
fi

RUN_ARGS=(--init --name "$NAME" "${NETWORK_ARGS[@]}" "${MOUNTS[@]}" "${ENV_ARGS[@]}")
if [[ "$DETACH" -eq 1 ]]; then
  RUN_ARGS=(-d "${RUN_ARGS[@]}")
fi
if [[ "$RM" -eq 1 ]]; then
  RUN_ARGS=(--rm "${RUN_ARGS[@]}")
fi

docker rm -f "$NAME" 2>/dev/null || true
echo "==> docker run ${IMAGE} (host home → ${HOST_HOME})"
exec docker run "${RUN_ARGS[@]}" "$IMAGE"
