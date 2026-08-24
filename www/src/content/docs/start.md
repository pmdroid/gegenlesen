---
title: Start
description: Pull the image, open Ledger, run the first review.
order: 1
---

Pull two images. Start the API with host network and the Docker socket. Open Ledger on loopback.

```bash
DATA="$HOME/gegenlesen-data"
mkdir -p "$DATA" "$HOME/gegenlesen-config"

docker pull ghcr.io/pmdroid/gegenlesen:main
docker pull ghcr.io/pmdroid/gegenlesen:runner-main

docker run --rm --init --name gegenlesen \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$DATA:$DATA" \
  -v "$HOME/gegenlesen-config:/app/config" \
  -e GEGENLESEN_DATA_DIR="$DATA" \
  -e GEGENLESEN_OPENCODE_IMAGE=ghcr.io/pmdroid/gegenlesen:runner-main \
  ghcr.io/pmdroid/gegenlesen:main
```

Open [http://127.0.0.1:8080](http://127.0.0.1:8080). Use **setup** to pick the two reviewers, the judge, the miner, and paste an OpenRouter key. That writes `gegenlesen.json` in the mounted config dir.

`--network host` and the matching data path are required. The API starts runner containers and talks to OpenCode on `127.0.0.1`. Details: [Docker](/docs/docker).

## Start a review

From the repo you want read, on the host:

```bash
gegenlesen review
```

That packs committed `HEAD` (`gegenlesen pack`) and `POST`s `/api/jobs`. Incremental:

```bash
gegenlesen review --parent <job-id>
```

The CLI talks to `http://127.0.0.1:8080` unless you set `GEGENLESEN_URL`.

Harvest of a large tree needs two knobs: the server miner deadline (`limits.mine_timeout_sec` in `gegenlesen.json`, or `GEGENLESEN_MINE_TIMEOUT_SEC`; default 1h, max 12h) and how long the CLI waits (`gegenlesen harvest --timeout 4h` or `GEGENLESEN_TIMEOUT`). `--timeout` only polls. The miner still dies at `mine_timeout_sec`.

A review of a repo with no **succeeded** harvest fails closed (`harvest_required`) before reviewers run. If the pack has no repository name, the error is `repository_unresolved`. Run `gegenlesen harvest` first, then review again. A harvest left in `needs_rejudge` does not count.

## From source

On a Mac, Docker Desktop does not share loopback the way a Linux box does. Build with Xcode’s Swift. Mixing it with Command Line Tools `/usr/bin/swift` produces a module version error. `./scripts/swift` and `make` set `DEVELOPER_DIR` for you.

```bash
scripts/build-runner.sh
make run
```

`make run` starts the API on `127.0.0.1:8080` and the Ledger Vite app on port 5173.

API only:

```bash
./scripts/swift run GegenlesenAPI serve --data-dir ./var --bind 127.0.0.1 --port 8080
```
