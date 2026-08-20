---
title: Security
description: No auth. Isolation is bind, extract, and Docker.
order: 7
---

v1 has no login. Treat this as a single-tenant box.

- Bind `127.0.0.1`. A non-loopback bind refuses to start unless `GEGENLESEN_ALLOW_REMOTE=1`. The Docker image uses `--network host` and still binds loopback. GitHub tokens stay in the Action. The API never sees them.
- The API container mounts the host Docker socket. Treat that host as single-tenant.
- Extract is libarchive, two-pass. Never `tar -xf`.
- Agent edit is an allowlist of `.gegenlesen` contract files. `task` is denied. Built-in OpenCode agents are off.
- Uploaded `opencode.json` and `.opencode/` are copied for audit, then renamed `*.gegenlesen-disabled`.
- `OPENCODE_CONFIG_CONTENT` is the sealed policy (`mcp: {}`, `plugin: []`).
- Command checkers do not inherit API keys. They run `--network none`.
- One agent job at a time. Retries are 0.
- On boot: `docker rm -f gegenlesen-*`, fail in-flight jobs, re-queue rows that never started.
