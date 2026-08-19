---
title: Start
description: Build Gegenlesen and run the first review.
---

Use Xcode’s Swift. Mixing it with Command Line Tools `/usr/bin/swift` produces a module version error. `./scripts/swift` and `make` set `DEVELOPER_DIR` for you.

## Run the service

```bash
cp config/gegenlesen.example.json config/gegenlesen.json
export OPENROUTER_API_KEY=…
scripts/build-runner.sh
make run
```

`make run` starts the API on `127.0.0.1:8080` and the Ledger Vite app on port 5173.

To start only the API:

```bash
./scripts/swift run GegenlesenAPI serve --data-dir ./var --bind 127.0.0.1 --port 8080
```

## Start a review

From the repo you want read:

```bash
gegenlesen review
```

That packs the working tree with `scripts/pack-repo.sh` and `POST`s `/api/jobs`. Incremental:

```bash
gegenlesen review --parent <job-id>
```

## Docs site

```bash
cd www && npm install && npm run dev
```

Astro serves this site on port 4321. `make docs` does the same from the repo root.

## After the rename

If you still have a `var/meister.sqlite` from the old name, stop the API and rename it:

```bash
mv var/meister.sqlite var/gegenlesen.sqlite
```

Rebuild the runner image. The tag is now `gegenlesen/opencode-runner:0.1.0`.
