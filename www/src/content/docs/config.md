---
title: Config
description: Files, env vars, and Docker image for gegenlesen.
order: 6
---

Ledger **setup** writes `config/gegenlesen.json` (gitignored), including models and `openrouter_api_key`. You can still copy `config/gegenlesen.example.json` and set `OPENROUTER_API_KEY` in the environment.

Override the path with `GEGENLESEN_CONFIG`. GET `/api/settings` never returns the key.

## Env

| Variable | What |
| --- | --- |
| `OPENROUTER_API_KEY` | Reviewers, judge, miner |
| `GEGENLESEN_URL` | CLI API base. Default `http://127.0.0.1:8080` |
| `GEGENLESEN_ALLOW_REMOTE=1` | Allow a non-loopback bind |
| `GEGENLESEN_SKIP_AGENT=1` | Deterministic path only. Used in tests |
| `GEGENLESEN_BIND` / `GEGENLESEN_PORT` / `GEGENLESEN_DATA_DIR` | Listen and store |
| `GEGENLESEN_HOST_HOME` | Host home inside the API container (default: process home). Set to `/host-home` when mounting `~/.claude`, `~/.cursor`, etc. for ACP Setup auth |
| `GEGENLESEN_MODEL_A` / `GEGENLESEN_MODEL_B` / `GEGENLESEN_JUDGE_MODEL` | Model ids |
| `GEGENLESEN_MINE_ENGINE` / `GEGENLESEN_MINE_MODEL` | Harvest and corpus miner slot |
| `GEGENLESEN_LEARN_ENGINE` / `GEGENLESEN_LEARN_MODEL` | Job Learn and architecture card slot |
| `GEGENLESEN_LEARN_INTERVAL_MINUTES` | Sweep. `0` disables |
| `GEGENLESEN_DOCKER` | `docker` binary |
| `GEGENLESEN_DOCKER_CPUS` | Runner `--cpus`. Default `2` |
| `GEGENLESEN_DOCKER_MEMORY` | Runner `--memory`. Default `4g` |
| `GEGENLESEN_DOCKER_NPROC` | Optional `--ulimit nproc=` (per-uid, not container-scoped). Default unset. Set only with userns-remap or a dedicated service uid; `--pids-limit 256` is the container cap |
| `GEGENLESEN_OPENCODE_IMAGE` | Runner image. From source: `gegenlesen/opencode-runner:0.1.0`. Docker image default: `ghcr.io/pmdroid/gegenlesen:runner-main` |
| `GEGENLESEN_SCANNER_IMAGE` | Scanner image. From source: `gegenlesen/scanner:0.1.0`. Docker image default: `ghcr.io/pmdroid/gegenlesen:scanner-main`. Empty skips the scanner container. |
| `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `CODEX_API_KEY` | ACP engine keys forwarded into runner containers |
| `CURSOR_API_KEY` / `CURSOR_AUTH_TOKEN` | Cursor agent auth |
| `XAI_API_KEY` / `GROK_API_KEY` | Grok agent auth |

## Docker

The API image is `ghcr.io/pmdroid/gegenlesen` (`:main` on the default branch, semver on tags). The runner is the same package, tag `runner-main` or `runner-0.1.0`. The scanner is `scanner-main` or `scanner-0.1.0`. How to run it: [Docker](/docs/docker).

Local runner build:

```bash
scripts/build-runner.sh
```

Image tag: `gegenlesen/opencode-runner:0.1.0`. Never write `:latest` into `config/gegenlesen.json`. CI may tag the GHCR runner `:latest` on a release; pin the digest or the semver tag in config.

The runner user is `gegenlesen`. Sealed config is bind-mounted at `/opt/gegenlesen/opencode` and seeded onto a tmpfs home so `opencode run` can write.

Egress network: `gegenlesen-egress`.
