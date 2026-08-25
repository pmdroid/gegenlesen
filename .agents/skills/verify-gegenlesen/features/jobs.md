# Jobs

The jobs list is Ledger home. It shows queue depth, status filters, a title filter, and each review's pipeline rail. Job detail is findings, thumbs, learn, and merge-intent.

## Sub-features

- `jobs-empty` shows the empty copy when this instance has no jobs.
- `jobs-filter` narrows by running / queued / succeeded / failed and by title.
- `jobs-open` opens one job from its title link.
- `jobs-detail` shows status, pipeline rail, findings, and log.
- `jobs-merge-intent` records would-you-merge-unread on a succeeded job with risk.

## How to get to it (user POV)

- Open Ledger at `/` (nav `jobs`).
- Click a job title on the list, or open `/jobs/<id>`.
- After `gegenlesen review`, the new row appears on `/` without a refresh longer than the 2s poll.

## Driving it with drive.sh

Preconditions:

- Default launch (dummy key, skip-agent).
- Doctor is `ok`.
- For `jobs-empty`, no jobs exist yet. Run this before `cli-review`.
- For detail and merge-intent, a succeeded job exists (see [CLI review](./cli-review.md)).

- **Empty list.** Open home. Run `.agents/skills/verify-gegenlesen/drive.sh shot / --label jobs-empty`. The page shows `No jobs yet. In a repo run \`gegenlesen review\`.` plus `queue 0 · running 0`. Brand `gegenlesen` and `api 127.0.0.1:` are visible.
- **Filters.** With at least one job, click `succeeded`. Run `.agents/skills/verify-gegenlesen/drive.sh shot / --label jobs-filter-succeeded` after clicking the `succeeded` chip (or drive that click in a headed session). The list contains only succeeded rows. Type a title fragment in the `filter jobs` textbox. Non-matching rows disappear. Click `all` to restore.
- **Open job.** Click the job title link. Land on `/jobs/<id>`. Status text is `succeeded` (skip-agent) or a live phase. Pipeline rail labels are `pack`, `identify`, `det`, `A ∥ B`, `judge`.
- **Findings.** Skip-agent jobs often have no kept findings. The empty copy is `No findings yet.` or `No kept findings. Toggle show dropped to inspect judge drops.` Capture that, then GET `/api/jobs/<id>` and keep the body as `job-detail.json`.
- **Merge-intent.** On a succeeded job with `risk` and `safe_unread` still null, the copy `would you have merged this unread?` appears with buttons `yes` and `no`. Click `yes`. The page then shows `labeled would merge unread`. Re-GET `/api/jobs/<id>` and assert `risk.safe_unread` is true.
- **Proof.** `jobs-empty.png` / `.aria.txt` for the empty path, plus `cli-review-job.json` and a `/jobs/<id>` shot for the populated path. List and detail both show the same job id.

## Gotchas

- List polls every 2s. A shot taken immediately after `cli-review` can still be empty. Wait for the title link or GET `/api/jobs` first.
- `running` is the chip id `active`. Accessible name is `running`, not `active`.
- Failed jobs show `error_message` in the chip instead of the word `failed`.
- Merge-intent writes `risk.safe_unread` only. It never pushes git.
- Skip-agent succeeded jobs include reason `reviewers_skipped`. That is not a full review.
