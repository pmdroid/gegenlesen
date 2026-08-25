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
| `GEGENLESEN_MODEL_A` / `GEGENLESEN_MODEL_B` / `GEGENLESEN_JUDGE_MODEL` | Model ids |
| `GEGENLESEN_LEARN_INTERVAL_MINUTES` | Sweep. `0` disables |
| `GEGENLESEN_DOCKER` | `docker` binary |
| `GEGENLESEN_OPENCODE_IMAGE` | Runner image. From source: `gegenlesen/opencode-runner:0.1.0`. Docker image default: `ghcr.io/pmdroid/gegenlesen:runner-main` |
| `GEGENLESEN_SCANNER_IMAGE` | Scanner image. From source: `gegenlesen/scanner:0.1.0`. Docker image default: `ghcr.io/pmdroid/gegenlesen:scanner-main`. Empty skips the scanner container. |

## Docker

The API image is `ghcr.io/pmdroid/gegenlesen` (`:main` on the default branch, semver on tags). The runner is the same package, tag `runner-main` or `runner-0.1.0`. The scanner is `scanner-main` or `scanner-0.1.0`. How to run it: [Docker](/docs/docker).

Local runner build:

```bash
scripts/build-runner.sh
```

Image tag: `gegenlesen/opencode-runner:0.1.0`. Never write `:latest` into `config/gegenlesen.json`. CI may tag the GHCR runner `:latest` on a release; pin the digest or the semver tag in config.

The runner user is `gegenlesen`. Sealed config is bind-mounted at `/opt/gegenlesen/opencode` and seeded onto a tmpfs home so `opencode run` can write.

Egress network: `gegenlesen-egress`.
