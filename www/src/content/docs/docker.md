---
title: Docker
description: Host network, matching data path, agent auth mounts, compose, and a local image build.
order: 2
---

The published images live on one GHCR package: `ghcr.io/pmdroid/gegenlesen:main` (API), `ghcr.io/pmdroid/gegenlesen:runner-main` (OpenCode), per-engine ACP runners (`claude-runner-main`, `codex-runner-main`, `cursor-runner-main`, `grok-runner-main`), and `ghcr.io/pmdroid/gegenlesen:scanner-main`. Version tags are `:0.1.12`, `:runner-0.1.12`, and so on. The first-run command is on [Start](/docs/start).

## Why host network and a matching data path

The API does not call the model. It `docker run`s the runner image and talks to OpenCode on `127.0.0.1`. `--network host` puts the API on the host’s loopback, so OpenCode’s `-p 127.0.0.1:…:4096` is reachable.

The data directory must be the **same path** on the host and in the container. The API bind-mounts workspaces into the runner, and the daemon on the host resolves those paths.

Mount the Docker socket so the API can start those containers. Treat the host as single-tenant.

Docker Desktop on a Mac does not share `127.0.0.1` this way. Use `./scripts/docker-run.sh` (port publish on `0.0.0.0:8080`) or [from source](/docs/start#from-source).

## ACP agent folders

Ledger **Setup** probes CLI login files under the host home (`~/.claude`, `~/.codex`, `~/.cursor`, `~/.grok`). When the API runs in Docker, mount those paths and set:

```bash
-e GEGENLESEN_HOST_HOME=/host-home
-v "$HOME/.claude:/host-home/.claude:ro"
# … same pattern for .codex, .cursor, .grok
```

`scripts/docker-run.sh` adds mounts only for paths that exist. Provider API keys can still be passed with `-e ANTHROPIC_API_KEY=…` etc.

Do not turn on Docker userns-remap to contain runner process counts. Remap maps container uid 1000 to a host subuid, so those credential binds (and anything the runner writes into them) land as the remapped owner. That needs a daemon restart and a re-chown of `~/.claude`, `~/.codex`, `~/.cursor`, `~/.grok` before the host CLIs work again. Process containment is `--pids-limit`; `GEGENLESEN_DOCKER_NPROC` is opt-in and unsafe on a shared host uid.

## Compose (Linux)

```bash
export GEGENLESEN_DATA_DIR="$HOME/gegenlesen-data"
mkdir -p "$GEGENLESEN_DATA_DIR"
docker compose up --build
```

`compose.yaml` mounts agent credential dirs and sets `GEGENLESEN_HOST_HOME=/host-home`.

## Mac helper

```bash
GEGENLESEN_DATA_DIR="$HOME/gegenlesen-data" \
GEGENLESEN_CONFIG_DIR="$HOME/gegenlesen-config" \
./scripts/docker-run.sh
```

Optional: `GEGENLESEN_PUBLISH_BIND=0.0.0.0` (default), `GEGENLESEN_IMAGE=ghcr.io/pmdroid/gegenlesen:0.1.12`.

## Build locally

```bash
make image
# or
./scripts/build-image.sh
```

That tags `ghcr.io/pmdroid/gegenlesen:local`. The local runner is still `scripts/build-runner.sh` → `gegenlesen/opencode-runner:0.1.0`. The local scanner is `scripts/build-scanner.sh` → `gegenlesen/scanner:0.1.0`.
