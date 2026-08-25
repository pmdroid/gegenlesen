# CLI review

`gegenlesen review` packs committed `HEAD` of the current repo and POSTs a job. Ledger then shows the row. Skip-agent launches finish after deterministic checks. A full launch runs reviewers A and B plus the judge.

## Sub-features

- `review-start` prints a job id and a terminal status.
- `review-ledger` shows that job on `/` and `/jobs/<id>`.
- `review-skip-agent` succeeds with risk reason `reviewers_skipped` and no reviewer timings.
- `review-status` re-reads the job with `gegenlesen status <id>`.
- `review-incremental` is `--parent <job-id>` after a succeeded job on later commits. Not part of the default proof.

## How to get to it (user POV)

- In a git repo, `gegenlesen review` (optional base ref).
- `gegenlesen status` / `gegenlesen status <id>`.
- Ledger `/` after the job is accepted.

## Driving it with drive.sh

Preconditions:

- Default launch (skip-agent, dummy key). Doctor is `ok`.
- `.build/debug/gegenlesen` exists (launch builds it).
- For a full A/B review, relaunch with `--with-agent` and a real `OPENROUTER_API_KEY`. Docker and the runner image must work. That is a different proof.

- **Start.** Run `.agents/skills/verify-gegenlesen/drive.sh cli-review`. Exit 0. First stdout line is a UUID job id. A later line is `succeeded`. File `cli-review.txt` holds that output.
- **Job JSON.** `cli-review` also writes `cli-review-job.json` from `GET /api/jobs/<id>`. `status` is `succeeded`. `risk.reasons` contains `reviewers_skipped`. `title` is the fixture pack name or repo title.
- **Ledger list.** Run `.agents/skills/verify-gegenlesen/drive.sh shot / --label jobs-after-review`. A title link for that job is visible. Status chip `succeeded`.
- **Ledger detail.** Shot `/jobs/<id>` with label `job-detail`. Pipeline rail is complete. Findings empty copy is acceptable on this fixture.
- **CLI status.** From any cwd, `GEGENLESEN_URL=<baseUrl> .build/debug/gegenlesen status <id>`. Stdout contains the same id and `succeeded`.
- **Proof.** `cli-review.txt` + `cli-review-job.json` + `jobs-after-review` screenshot. JSON without a Ledger shot does not prove the jobs page. A Ledger shot without CLI stdout does not prove the user entry point.

## Gotchas

- Uncommitted files are invisible. The helper fixture commits `v1` then `v2` so the pack has a diff.
- Default CLI URL is `http://127.0.0.1:8080`. Forgetting `GEGENLESEN_URL` talks to whatever owns 8080 (OrbStack on this machine), not the verify instance.
- Timeout flag only polls. The server still kills the miner at `limits.mine_timeout_sec`. Skip-agent reviews should finish in seconds.
- `gegenlesen review --parent` needs a succeeded parent with SHAs and job files. The fixture helper does not pass `--parent`.
- Do not start a second full `--with-agent` review of the same SHA.
- Harvest is `gegenlesen harvest`, not this feature. Skip-agent harvest writes disabled drafts without a miner. `cli-review` runs harvest once per launch because reviews fail with `harvest_required` otherwise. That harvest job appears on `/`. Run `jobs-empty` before the first `cli-review`.
