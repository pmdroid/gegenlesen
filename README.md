# Meister

Single-tenant PR review. The **CLI** starts a review (`meister review`). The **web UI** is management only: jobs, findings + 👍/👎, rules, context, learnings. Reviewers run in Docker; a judge drops unsupported findings.

There is no auth in v1. Bind `127.0.0.1`. One agent job at a time.

**How it works (HTML):** [`docs/overview.html`](docs/overview.html)

**Admin UI (locked: Ledger):** [`docs/ui-ledger.html`](docs/ui-ledger.html)

**Full design (approved):** [`docs/meister-pr-review-service.md`](docs/meister-pr-review-service.md)

**Types, classes, HTTP, file contracts** (use this to cross-check other agents):

| File | What |
| --- | --- |
| [`docs/technical-plan.md`](docs/technical-plan.md) | Swift types, actors, protocols, state machine, checklist |
| [`docs/contracts/MeisterTypes.swift`](docs/contracts/MeisterTypes.swift) | Copy into `Sources/` in PR 2 |
| [`docs/contracts/api.ts`](docs/contracts/api.ts) | Copy into `frontend/src/` in PR 1 |
| [`schemas/openapi.yaml`](schemas/openapi.yaml) | HTTP surface |
| [`schemas/findings.agent.json`](schemas/findings.agent.json) | Agent `.meister/findings.json` |
| [`schemas/judge.json`](schemas/judge.json) | Judge `.meister/judge.json` |
| [`schemas/judge-input.json`](schemas/judge-input.json) | Host → judge file |
| [`schemas/create-job-meta.json`](schemas/create-job-meta.json) | `POST /api/jobs` `meta` part |

If a type or wire field disagrees with the design narrative, **the technical plan + schemas win**.

This repo is greenfield. The design invents the target layout; implementation starts at PR 1.

---

## Pipeline

```
meister review  (CLI packs cwd, POST /api/jobs)
  → unpack (libarchive, not tar -xf)
  → identify git range
  → load matching rules (handwritten + mined)
  → deterministic checks on the host (regex, deny-list, sibling tests)
  → if there is new work: OpenCode reviewers A and B in parallel
  → host writes .meister/judge-input.json (union of both)
  → host writes .meister/judge-input.json (stable IDs + evidence)
  → OpenCode judge (separate model) keep / drop / downgrade
  → persist pre- and post-judge findings
  → React UI
```

Deterministic rules run first so cheap failures do not spend a model call. The judge runs last and only sees candidate findings plus the evidence the reviewer cited. Default is **keep**. The host drops a finding only when the cited lines do not support it.

## Review scopes

| Scope | What you upload | What gets reviewed |
| --- | --- | --- |
| **Full change** | Tarball from `scripts/pack-repo.sh`: working tree + `.meister/diff.patch` + optional thin git bundle | The whole identified diff |
| **Incremental** | New tarball + `parent_job_id` of a succeeded job | Only new hunks. Prior findings become `still_open` / `resolved` / `relocated`. If nothing new, OpenCode is not started |

HTTP accepts `archive` + `meta` always. `patch` is optional. A 422 happens only when `meta` lacks both SHAs **and** there is no `patch` part. In-archive `.git`, bundle, or `.meister/diff.patch` are discovered after extract. If identifying still has no history, the **job** fails (`no_change_set`), not the POST.

## Rules

Two sources, two kinds.

| | Deterministic | Semantic |
| --- | --- | --- |
| **Handwritten** | YAML/Markdown in the UI: regex, deny-list APIs, sibling-test files, optional sandbox `command` | Natural-language rule + optional few-shots |
| **Mined** | Extracted from a historical PR corpus, disabled until promoted | Same, retrieved by path glob + SQLite FTS5 |

`command` checkers and the **OpenAPI/Swagger break check** (`oasdiff`) run in the runner image **without** OpenCode, **without** provider keys, `--network none`.

## Stack

| Layer | Choice |
| --- | --- |
| API | Swift 6, Vapor, first-party multipart, in-process 1-worker queue (retries = 0, no Redis) |
| Store | SQLite via GRDB + FTS5, filesystem blobs under `var/` |
| Frontend | React 19, Vite, TypeScript, TanStack Query, poll every 2s |
| Agent | `anomalyco/opencode` via **`opencode serve` HTTP** in Docker. Host talks to `127.0.0.1:ephemeral` only. |
| Extract | libarchive two-pass. Never `tar -xf` |
| Host deps | Swift 6.0+, Docker 24+, git 2.40+, libarchive, Node 20+ (dev/build only) |

The host never calls the model API. Reviewer and judge both run as one-shot `docker run`.

## Security (no auth)

- Bind `127.0.0.1`. Refuse `0.0.0.0` unless `MEISTER_ALLOW_REMOTE=1`.
- Agent `edit` is an allowlist of `.meister` contract files only. `task` is denied. Built-in OpenCode agents are disabled.
- Uploaded `opencode.json` / `.opencode/` are copied for audit, then renamed `*.meister-disabled` so OpenCode cannot merge MCP, plugins, or extra bash allows.
- `OPENCODE_CONFIG_CONTENT` is the sealed policy (`mcp: {}`, `plugin: []`).
- Command checkers do not inherit API keys.
- Memory queue is not durable. On boot: `docker rm -f meister-*`, fail in-flight jobs, re-queue never-started rows.

## Key decisions

See the design for rationale. Locked defaults:

1. Vapor HTTP. GRDB for SQLite/FTS5. No Redis.
2. SQLite/GRDB + FTS5 **and** local embeddings (BLOB + cosine). No hosted vector DB.
3. OpenCode is `anomalyco/opencode`, not the archived Go CLI.
4. Findings are a file (`.meister/findings.json`), not the event stream.
5. Every job always runs both reviewer models, then one judge.
6. One active agent job. Retries = 0.
7. Incremental is a parent pointer + stored SHA-256s. Works without `.git`.
8. v1 egress is an isolated Docker bridge, no published ports.
9. Default models: `model_a = anthropic/claude-sonnet-4-5`, `model_b = openai/gpt-5.2`, `judge = model_a`.
10. Ship 5–10 generic seed rules. House rules go in the UI.

## Quality bar

| Item | Target |
| --- | --- |
| Deterministic phase | < 30s for ≤ 200 changed files |
| Identifying | < 60s |
| Reviewer | hard kill at 900s |
| Judge | hard kill at 300s |
| Concurrency | 1 agent job |
| Archive | 100 MiB compressed / 2 GiB uncompressed / 50k files |
| Queued archives | Σ ≤ 2 GiB or HTTP 507 |
| Workspace TTL | 24h |

## PR plan

Independently mergeable increments. `swift test` and the frontend typecheck stay green. Model keys are not needed until PR 6.

| PR | Title | Depends on |
| --- | --- | --- |
| 1 | Skeleton: Vapor API + React app + runner stub | — |
| 2 | SQLite store, migrations, blob layout | 1 |
| 3 | Safe tar extract + git change-set identification | 2 |
| 4 | Jobs API + queue + state machine (no agent; skip-agent path succeeds) | 3 |
| 5 | Rule schema, CRUD, seed rules, deterministic engine | 4 |
| 6 | Docker OpenCode runner + reviewer pass (quarantine, redaction, evil-fixture tests) | 5 |
| 7 | Findings UI + job detail | 6 |
| 8 | Judge pass | 6, 7 |
| 9 | Incremental scope (“diff of the diff”) | 3, 4, 7 |
| 10 | Deterministic `command` checker in sandbox | 5, 6 |
| 11 | Corpus ingest + miner | 2, 6 |
| 12 | FTS retrieval + prompt budget | 5, 11 |

Later, not v1: GitHub App, SSE, second worker, embeddings, apply-suggested-patch.

## Intended layout

```
meister/
  README.md
  docs/meister-pr-review-service.md
  Package.swift
  Sources/MeisterAPI/          # HTTP
  Sources/MeisterCore/         # domain, jobs, rules, store
  Sources/MeisterAgent/        # docker + opencode runner
  Sources/CLibArchive/         # safe extract
  frontend/                    # React + Vite + TypeScript
  rules/                       # seed handwritten rules
  docker/opencode-runner/      # image that contains opencode
  scripts/pack-repo.sh         # preferred upload producer
  config/meister.example.json
  var/                         # sqlite, blobs, workspaces (gitignored)
```

## Run

Use the Xcode toolchain (`Command Line Tools` cannot import Swift Testing / XCTest, and mixing toolchains poisons `.build`).

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
scripts/dev.sh                      # API :8080 + Vite; creates meister-egress
# or:
swift run MeisterAPI serve --data-dir ./var --bind 127.0.0.1 --port 8080
cd frontend && npm run dev          # proxies /api → :8080
scripts/build-runner.sh             # meister/opencode-runner:0.1.0
```
