---
title: Config
description: Files, env vars, and Docker image for Gegenlesen.
---

Copy `config/gegenlesen.example.json` to `config/gegenlesen.json`. That file is gitignored.

Override the path with `GEGENLESEN_CONFIG`.

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

## Docker

```bash
scripts/build-runner.sh
```

Image tag: `gegenlesen/opencode-runner:0.1.0`. Never tag `:latest` in config.

The runner user is `gegenlesen`. Sealed config is bind-mounted at `/opt/gegenlesen/opencode` and seeded onto a tmpfs home so `opencode run` can write.

Egress network: `gegenlesen-egress`.
