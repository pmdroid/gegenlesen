---
title: Docker
description: Run gegenlesen from a published image. Linux, host network, Docker socket.
order: 2
---

The image is `ghcr.io/pmdroid/gegenlesen`. CI builds it from `main` (`:main`) and from version tags (`:1.2.3`). The OpenCode runner is a second image, `ghcr.io/pmdroid/gegenlesen/runner`.

This is a Linux path. On a Mac, `make run` is still the one that fits. Docker Desktop does not share `127.0.0.1` with `--network host` the way a Linux box does, and OpenCode publishes loopback ports that the API has to reach.

## Pull

```bash
docker pull ghcr.io/pmdroid/gegenlesen:main
docker pull ghcr.io/pmdroid/gegenlesen/runner:main
```

## Run

The data directory must be the **same path** on the host and in the container. The API bind-mounts workspaces into the runner, and the daemon on the host resolves those paths.

`--network host` puts the API on the host’s `127.0.0.1:8080`. OpenCode’s `-p 127.0.0.1:…:4096` lands on the same loopback. Mount the Docker socket so the API can start runner containers.

```bash
DATA="$HOME/gegenlesen-data"
mkdir -p "$DATA" "$HOME/gegenlesen-config"

docker run --rm --name gegenlesen \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$DATA:$DATA" \
  -v "$HOME/gegenlesen-config:/app/config" \
  -e GEGENLESEN_DATA_DIR="$DATA" \
  -e GEGENLESEN_OPENCODE_IMAGE=ghcr.io/pmdroid/gegenlesen/runner:main \
  ghcr.io/pmdroid/gegenlesen:main
```

Open [http://127.0.0.1:8080](http://127.0.0.1:8080). Ledger **setup** writes `/app/config/gegenlesen.json` on the mounted config dir. From a repo, `gegenlesen review` still runs on the host and talks to `http://127.0.0.1:8080`.

Compose does the same:

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

That tags `ghcr.io/pmdroid/gegenlesen:local`. The runner is still `scripts/build-runner.sh` → `gegenlesen/opencode-runner:0.1.0`.

## Why host network and a matching data path

The API does not call the model. It starts `gegenlesen/opencode-runner` (or the GHCR runner tag) with `docker run` and talks to OpenCode on `127.0.0.1`. Nested port publish without host network would publish on the **host** loopback while the API listens in the container. Matching data paths keep `--mount type=bind,src=…` valid for the daemon.
