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
IMAGE="${GEGENLESEN_IMAGE:-ghcr.io/pmdroid/gegenlesen:0.1.24}"
PUBLISH_BIND="${GEGENLESEN_PUBLISH_BIND:-0.0.0.0}"
PORT="${GEGENLESEN_PORT:-8080}"
NAME="${GEGENLESEN_CONTAINER_NAME:-gegenlesen}"
RUNNER_TAG="${GEGENLESEN_RUNNER_TAG:-0.1.24}"
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

sync_claude_credentials() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  local raw dest="${HOME}/.claude/.credentials.json"
  raw="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)" || return 0
  mkdir -p "${HOME}/.claude/debug"
  python3 - "$raw" "$dest" <<'PY'
import json, os, sys
raw, dest = sys.argv[1], sys.argv[2]
try:
    obj = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
oauth = obj.get("claudeAiOauth")
if not oauth and obj.get("accessToken"):
    oauth = obj
if not oauth or (not oauth.get("accessToken") and not oauth.get("refreshToken")):
    sys.exit(0)
tmp = dest + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump({"claudeAiOauth": oauth}, f, sort_keys=True)
    f.write("\n")
os.replace(tmp, dest)
PY
}

sync_claude_credentials

sync_cursor_auth_token() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  if [[ -n "${CURSOR_AUTH_TOKEN:-}" ]]; then
    return 0
  fi
  local token
  token="$(security find-generic-password -s cursor-access-token -a cursor-user -w 2>/dev/null)" || return 0
  CURSOR_AUTH_TOKEN="$token"
  export CURSOR_AUTH_TOKEN
}

sync_cursor_auth_token

AGENT_CACHE="${GEGENLESEN_AGENT_CACHE:-${DATA}/container-agents}"

ensure_cursor_agent() {
  local root="${AGENT_CACHE}/cursor-root/opt/cursor-agent"
  if [[ -d "${root}/versions" ]]; then
    return 0
  fi
  mkdir -p "${AGENT_CACHE}/cursor-root/opt"
  local cid="gegenlesen-agent-extract-cursor-$$"
  echo "==> extracting cursor-agent bundle from ${REGISTRY}:cursor-runner-${RUNNER_TAG}"
  docker rm -f "$cid" 2>/dev/null || true
  docker create --name "$cid" "${REGISTRY}:cursor-runner-${RUNNER_TAG}" >/dev/null
  docker cp "${cid}:/opt/cursor-agent" "${AGENT_CACHE}/cursor-root/opt/cursor-agent"
  docker rm "$cid" >/dev/null
  chmod -R a+rx "${AGENT_CACHE}/cursor-root/opt/cursor-agent"
}

ensure_grok_agent() {
  local dest="${AGENT_CACHE}/grok-agent"
  if [[ -f "$dest" ]]; then
    return 0
  fi
  mkdir -p "$AGENT_CACHE"
  local cid="gegenlesen-agent-extract-grok-$$"
  echo "==> extracting grok from ${REGISTRY}:grok-runner-${RUNNER_TAG}"
  docker rm -f "$cid" 2>/dev/null || true
  docker create --name "$cid" "${REGISTRY}:grok-runner-${RUNNER_TAG}" >/dev/null
  docker cp "${cid}:/usr/local/bin/agent" "$dest"
  docker rm "$cid" >/dev/null
  chmod 0755 "$dest"
}

ensure_cursor_agent
ensure_grok_agent

CURSOR_VERSION="$(ls "${AGENT_CACHE}/cursor-root/opt/cursor-agent/versions" | head -1)"
CURSOR_AGENT_PATH="/opt/cursor-agent/versions/${CURSOR_VERSION}/cursor-agent"

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

mount_if "${HOME}/.claude" "${HOST_HOME}/.claude" rw
mount_if "${HOME}/.codex" "${HOST_HOME}/.codex" rw
mount_if "${HOME}/.cursor" "${HOST_HOME}/.cursor" rw
mount_if "${HOME}/.grok" "${HOST_HOME}/.grok" rw
mount_if "${HOME}/.config/cursor" "${HOST_HOME}/.config/cursor"
MOUNTS+=(-v "${AGENT_CACHE}/cursor-root/opt/cursor-agent:/opt/cursor-agent:ro")
MOUNTS+=(-v "${AGENT_CACHE}/grok-agent:/usr/local/bin/grok:ro")
if [[ -f "${ROOT}/docker/runner-base/acp-models.mjs" ]]; then
  MOUNTS+=(-v "${ROOT}/docker/runner-base/acp-models.mjs:/app/docker/runner-base/acp-models.mjs:ro")
fi

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
  -e "GEGENLESEN_CURSOR_AGENT=${CURSOR_AGENT_PATH}"
  -e "GEGENLESEN_GROK_AGENT=/usr/local/bin/grok"
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
