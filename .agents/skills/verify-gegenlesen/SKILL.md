---
name: verify-gegenlesen
description: Drive the real gegenlesen Ledger UI (React SPA served by GegenlesenAPI) and the gegenlesen CLI on a live local instance, and capture screenshots, ARIA snapshots, and HTTP bodies. Use when a change needs to be shown working in Ledger or via `gegenlesen review`, not only in unit tests.
---

# Verify gegenlesen

gegenlesen is single-tenant PR review on this machine. The **CLI** starts a review (`gegenlesen review`). **Ledger** is the management UI: jobs, findings + thumbs, rules, context, learnings, setup. This skill launches an isolated API that serves Ledger, drives it the way a user would, and leaves proof on disk.

Other surfaces in this repo, not covered here:

- Marketing site in `www/` (`make docs`, port 4321)
- Docker image path in `compose.yaml` (Linux host network). Use `make run` / this skill from source on a Mac.

Read [`features/README.md`](./features/README.md) before driving. It is the maintained map. A proof that only drives one convenient entry point is incomplete when the map lists others.

## Launch

Do **not** run `make run` and do **not** bind `127.0.0.1:8080`. That port is often taken (OrbStack on this machine), and `make run` writes `./var` plus `config/gegenlesen.json`. Verification starts its own API on a free loopback port with a disposable data dir.

```bash
cd "$(git rev-parse --show-toplevel)"
export VERIFY_RUN=my-check
.agents/skills/verify-gegenlesen/drive.sh launch
```

Ready when `/api/health` answers. stdout prints the pid and `http://127.0.0.1:<port>`. Ledger is that origin (production path: `GegenlesenAPI` serves `frontend/dist`, not Vite on 5173).

Default launch sets `GEGENLESEN_SKIP_AGENT=1` and writes a dummy OpenRouter key into the isolated config so Ledger skips the first-run `/setup` redirect. Reviewers A/B and the judge do not run. `gegenlesen review` still unpacks, identifies, runs deterministic checks, then succeeds with risk reason `reviewers_skipped`.

Flags:

- `--no-key` omits the dummy key and clears `OPENROUTER_API_KEY`. Ledger redirects every route to `/setup`. Use this only for the setup feature.
- `--with-agent` leaves `GEGENLESEN_SKIP_AGENT` unset. Needs a real `OPENROUTER_API_KEY` in the environment, Docker, and the runner image. One agent job at a time on this host. Do not start a second full review of the same SHA.

Never join an already-running instance. If `VERIFY_RUN` already has a live pid, launch exits 1. Pick a new `VERIFY_RUN` to run side by side (ports and data dirs are per run).

## Doctor

Read-only. Run this first whenever anything looks off.

```bash
.agents/skills/verify-gegenlesen/drive.sh doctor
```

Exits 0 only when every required check is true: process alive, listen port owned by that pid, `/api/health` `{ok: true}`, settings bind `127.0.0.1` and port match, `GET /` is Ledger (`gegenlesen` in the HTML), data dir is under this run's evidence dir.

`openrouterConfigured` is true on a default launch (dummy key) and false on `--no-key`. `skipAgent` is true unless you passed `--with-agent`.

## Drive

Ledger has almost no `data-testid`. Prefer role + accessible name, then a wrapping `<label>` (Playwright `getByLabel`). Real handles:

| What | Handle |
| --- | --- |
| Brand | text `gegenlesen` in the topbar |
| Nav | links `jobs`, `rules`, `context`, `learnings`, `agents`, `setup` |
| API status | text matching `api 127.0.0.1:<port> · <version>` |
| Jobs filter | buttons `all`, `running`, `queued`, `succeeded`, `failed`; textbox `filter jobs` |
| Jobs empty | `No jobs yet. In a repo run \`gegenlesen review\`.` |
| New rule | link `new semantic rule` or `new auto-approve weight` |
| Rule editor | labels `title`, `instruction`, button `create` / `save` / `disable` / `delete` |
| Context note | heading `new note`, labels `title` and `body`, button `create` |
| Setup | heading `set up gegenlesen` on first run, else `models and key`; label `OpenRouter API key`; submit `save and continue` or `save` |

Wait for `api 127.0.0.1:` in the topbar before asserting page content. A screenshot taken during `api …` or `api down` is not a Ledger proof.

**Open a page**

```bash
.agents/skills/verify-gegenlesen/drive.sh shot /rules --label rules-list
```

**Create a handwritten semantic rule** (the cheap mutation used to prove this skill)

```bash
.agents/skills/verify-gegenlesen/drive.sh rules-create \
  --title "verify skill probe" \
  --instruction "Flag print() in production Swift."
.agents/skills/verify-gegenlesen/drive.sh api GET /api/rules --label rules-persisted

**Edit an agent prompt**

```bash
.agents/skills/verify-gegenlesen/drive.sh agents-save --id reviewer --text "verify agent override"
.agents/skills/verify-gegenlesen/drive.sh api GET /api/agents/reviewer --label agent-saved
.agents/skills/verify-gegenlesen/drive.sh agents-reset --id reviewer
```
```

Landed path is `/rules/<id>` (kebab title, suffix if that id was used even after delete). Then delete that rule through Ledger (`delete` on the editor) or `api DELETE /api/rules/<id>`. Keep the screenshots.

**CLI review** (skip-agent default)

```bash
.agents/skills/verify-gegenlesen/drive.sh cli-review
.agents/skills/verify-gegenlesen/drive.sh shot / --label jobs-after-review
```

`cli-review` makes a tiny git repo under the run cache, harvests it once, runs `.build/debug/gegenlesen review` with `GEGENLESEN_URL` pointed at this instance, and writes `cli-review-job.json`. `--probe` adds `Sources/Probe.swift` with `eval(__gegenlesen_probe__)`. Open `/jobs/<id>` for findings, the pipeline rail (`pack`, `identify`, `det`, `A ∥ B`, `judge`), and merge-intent `yes` / `no` once `risk.safe_unread` is null. The thumbs → Learn → second-review loop is [features/learnings.md](./features/learnings.md).

**HTTP** is for side effects and doctor, not a substitute for a Ledger click.

```bash
.agents/skills/verify-gegenlesen/drive.sh api GET /api/health --label health
.agents/skills/verify-gegenlesen/drive.sh api GET /api/jobs --label jobs
```

Do not POST `/api/jobs` yourself to "prove" Ledger. The user path is `gegenlesen review` (or `gegenlesen harvest`).

## Evidence

Everything lands in `~/.cache/gegenlesen/verify-gegenlesen/$VERIFY_RUN/` (outside the repo and outside `./var`). Cleanup deletes `data/`, `config/`, and `fixture-repo/`. It does not delete screenshots, ARIA dumps, HTTP captures, `api.log`, or `instance.json`.

| file | source |
| --- | --- |
| `<label>.png` | full-page Ledger screenshot, 1440×900, animations off |
| `<label>.aria.txt` | Playwright ARIA snapshot of `body` |
| `<label>.json` | landed URL, title, skip-agent flag, console errors |
| `cli-review.txt` | CLI stdout (job id + terminal status) |
| `cli-review-job.json` | `GET /api/jobs/<id>` after the CLI returns |
| `api.log` | GegenlesenAPI stderr/stdout |

Proof standards:

- Drive the real user path. Click Ledger controls. Start reviews with `gegenlesen review`, not a hand-rolled multipart POST, unless the feature under test is the HTTP route itself.
- Capture the action and the result. `rules-before` + `rules-create-form` + `rules-after`, not only the editor after save.
- Re-read from the API or by navigating away and back. A React query cache is not persistence.
- Seeded handwritten rules (`openapi-breaking-changes`, `use-project-logger`) come from `rules/*.yaml` on boot. Do not delete them. Probe titles must be unique (`verify skill probe`).
- `GEGENLESEN_SKIP_AGENT=1` skips reviewers, judge, miner, and OpenRouter. Confirm that skip by reading `risk.reasons` for `reviewers_skipped` and by noting that no Docker reviewer containers appear. Do not call a skip-agent job a full A/B review.
- `--with-agent` spends real OpenRouter quota and takes minutes. Use it only when the change is in the agent path.

## Cleanup

```bash
.agents/skills/verify-gegenlesen/drive.sh cleanup
```

Sends SIGTERM (then SIGKILL) to the pid recorded at launch. Removes the disposable data dir, isolated config, and fixture repo. Leaves evidence. Never `killall GegenlesenAPI` and never touch `./var` or `config/gegenlesen.json`.

Confirm the proof files are still in `~/.cache/gegenlesen/verify-gegenlesen/$VERIFY_RUN/` before you report.

Undo Ledger mutations (delete the probe rule or note) through the UI or `drive.sh api` before cleanup.

## Helpers

```bash
.agents/skills/verify-gegenlesen/drive.sh launch [--no-key] [--with-agent]
.agents/skills/verify-gegenlesen/drive.sh doctor
.agents/skills/verify-gegenlesen/drive.sh api [METHOD] PATH [--body JSON] [--label NAME]
.agents/skills/verify-gegenlesen/drive.sh shot PATH --label NAME
.agents/skills/verify-gegenlesen/drive.sh rules-create --title T --instruction I
.agents/skills/verify-gegenlesen/drive.sh context-create --title T --body B
.agents/skills/verify-gegenlesen/drive.sh agents-save --id ID --text TEXT
.agents/skills/verify-gegenlesen/drive.sh agents-reset --id ID
.agents/skills/verify-gegenlesen/drive.sh agents-improve --id ID --instruction TEXT
.agents/skills/verify-gegenlesen/drive.sh agents-reject --id ID
.agents/skills/verify-gegenlesen/drive.sh regex-rule-create --title T --pattern P
.agents/skills/verify-gegenlesen/drive.sh harvest
.agents/skills/verify-gegenlesen/drive.sh cli-review [--fresh] [--keep] [--advance-base] [--probe] [--label NAME]
.agents/skills/verify-gegenlesen/drive.sh job-thumb --down|--up
.agents/skills/verify-gegenlesen/drive.sh job-merge-intent --yes|--no
.agents/skills/verify-gegenlesen/drive.sh job-learn
.agents/skills/verify-gegenlesen/drive.sh job-should-be-rule
.agents/skills/verify-gegenlesen/drive.sh learning-accept [--kind KIND]
.agents/skills/verify-gegenlesen/drive.sh rule-promote --id ID
.agents/skills/verify-gegenlesen/drive.sh rule-disable --id ID
.agents/skills/verify-gegenlesen/drive.sh cleanup
```

`drive.sh` plus `browser.mjs`. Playwright is a skill-local npm dep and uses the installed Chrome (`channel: chrome`). `VERIFY_RUN` names the evidence dir. `VERIFY_HEADED=1` shows the browser.

## Gotchas

- Vite (`npm run dev` in `frontend/`, port 5173) proxies `/api` to **8080 only**. An isolated API on another port is invisible to Vite. Drive the API origin, not 5173.
- No login. Bind is loopback. `GEGENLESEN_ALLOW_REMOTE=1` is required for a non-loopback bind; this skill never sets that.
- First-run without a key redirects every path to `/setup`. Default launch plants a dummy key so other features are reachable.
- PUT `/api/settings` persists to `GEGENLESEN_CONFIG`. That is why launch uses an isolated file, not `config/gegenlesen.json`.
- One agent job at a time. skip-agent jobs still occupy the queue while they unpack.
- `frontend/dist` is gitignored. Launch builds it if `index.html` is missing.
- Swift must be Xcode's (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`), not `/usr/bin/swift`. `drive.sh` sets that the same way `scripts/swift` does.
