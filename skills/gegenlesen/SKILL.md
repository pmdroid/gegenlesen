---
name: gegenlesen
description: >
  Run a gegenlesen CLI self-review on the current git repo before push or PR.
  Use when about to git push, open a PR, or the operator asks for gegenlesen /
  self-review / pre-push / pre-PR review. Advisory only. Never auto-apply findings.
---

# gegenlesen self-review

Pack **committed** `HEAD` and send it to the local gegenlesen API (`gegenlesen review`). Two models plus a judge. You treat the kept findings as advice, verify them in the tree, then push.

## When

- Before `git push` or opening a PR, after the work is committed
- Operator says gegenlesen / self-review / pre-push / pre-PR

Skip prose-only docs unless they insist. Skip if they said not to review.

## Preconditions

1. Work you want reviewed is **committed**. The pack is `git archive HEAD` plus `git diff <base> HEAD`. Uncommitted edits are invisible.
2. `gegenlesen` is on `PATH`.
3. API is up:

```bash
curl -sf "${GEGENLESEN_URL:-http://127.0.0.1:8080}/api/health"
```

If health fails, stop. Tell the operator to start gegenlesen. Do not invent findings. Do not push unless they say skip.

## Run

From the repo root:

```bash
gegenlesen review
```

Stdout: job id, then terminal status (`succeeded` / `failed` / `cancelled`). Exit 1 on failed or cancelled.

Optional base ref (otherwise merge-base with `origin/main` or `main`):

```bash
gegenlesen review origin/main
```

After a **succeeded** job on this branch, later commits can be incremental:

```bash
gegenlesen review --parent <job-id>
```

Do not start a second full review of the same SHA.

`GEGENLESEN_URL` defaults to `http://127.0.0.1:8080`. One agent job at a time.

If the CLI errors with timeout, the job is still running. Keep the printed id and poll:

```bash
gegenlesen status <job-id>
```

until status is `succeeded`, `failed`, or `cancelled`. Reviews often take several minutes.

```bash
gegenlesen cancel <job-id>
```

## Findings

CLI does not print findings. After `succeeded`:

```bash
curl -s "${GEGENLESEN_URL:-http://127.0.0.1:8080}/api/jobs/<job-id>"
```

`findings[]` fields that matter: `title`, `message`, `severity`, `file_path`, `start_line`, `end_line`, `snippet`, `judge_verdict`, `judge_severity`, `evidence_ok`, `lifecycle`, `suggested_patch`.

Act on a finding only when:

- `judge_verdict` is `keep` or `downgrade` (ignore `drop` / `unavailable`)
- `evidence_ok` is not `false`
- `lifecycle` is not `resolved`

`error` first, then `warning`, then `info`. Open Ledger at `http://127.0.0.1:8080/jobs/<job-id>` if you want the UI.

## After findings

- **Advisory.** Open the cited file and check the lines. Do not blind-apply `suggested_patch`.
- Fix what you accept at the right ownership boundary. Re-run focused tests.
- Re-review incrementally (`--parent`) after those commits.
- Report to the operator: job id, kept count, what you accepted or rejected and why, whether you will push.

Do not push a known `error` keep you have not addressed or explained.

Do not spawn a second review loop (no review-of-review). gegenlesen already runs two reviewers and a judge.

## acpbot

In an acpbot topic this is the house review. Run `gegenlesen review`; do not call `review_run` or `/review` for the same change unless the operator wants the ACP dual-agent panel as well. The `gegenlesen` binary must be on PATH. The API must already be up on `127.0.0.1:8080`.
