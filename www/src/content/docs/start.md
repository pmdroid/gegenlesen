---
title: Start
description: Build gegenlesen and run the first review.
order: 1
---

Use Xcode’s Swift. Mixing it with Command Line Tools `/usr/bin/swift` produces a module version error. `./scripts/swift` and `make` set `DEVELOPER_DIR` for you.

## Run the service

```bash
scripts/build-runner.sh
make run
```

`make run` starts the API on `127.0.0.1:8080` and the Ledger Vite app on port 5173. Open Ledger and use **setup** to pick the two reviewers, the judge, and paste an OpenRouter key. That writes `config/gegenlesen.json`. You can still export `OPENROUTER_API_KEY` instead.

To start only the API:

```bash
./scripts/swift run GegenlesenAPI serve --data-dir ./var --bind 127.0.0.1 --port 8080
```

Linux can run the published image instead. See [Docker](/docs/docker).

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

The public site is [gegenlesen.dev](https://gegenlesen.dev). `make docs` serves the same pages on port 4321.

## After the rename

If you still have a `var/meister.sqlite` from the old name, stop the API and rename it:

```bash
mv var/meister.sqlite var/gegenlesen.sqlite
```

Rebuild the runner image. The tag is now `gegenlesen/opencode-runner:0.1.0`.
