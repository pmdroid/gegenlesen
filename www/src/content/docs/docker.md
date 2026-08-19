---
title: Docker
description: Host network, matching data path, compose, and a local image build.
order: 2
---

The published images are `ghcr.io/pmdroid/gegenlesen` and `ghcr.io/pmdroid/gegenlesen/runner`. CI builds them from `main` (`:main`) and from version tags (`:1.2.3`). The first-run command is on [Start](/docs/start).

## Why host network and a matching data path

The API does not call the model. It `docker run`s the runner image and talks to OpenCode on `127.0.0.1`. `--network host` puts the API on the host’s loopback, so OpenCode’s `-p 127.0.0.1:…:4096` is reachable.

The data directory must be the **same path** on the host and in the container. The API bind-mounts workspaces into the runner, and the daemon on the host resolves those paths.

Mount the Docker socket so the API can start those containers. Treat the host as single-tenant.

Docker Desktop on a Mac does not share `127.0.0.1` this way. Use [from source](/docs/start#from-source) there.

## Compose

```bash
export GEGENLESEN_DATA_DIR="$HOME/gegenlesen-data"
mkdir -p "$GEGENLESEN_DATA_DIR"
docker compose up --build
```

## Build locally

```bash
make image
# or
./scripts/build-image.sh
```

That tags `ghcr.io/pmdroid/gegenlesen:local`. The local runner is still `scripts/build-runner.sh` → `gegenlesen/opencode-runner:0.1.0`.
