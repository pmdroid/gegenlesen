# Learnings loop

A succeeded review can be labeled in Ledger: thumbs on findings, merge-intent, then Learn. The next skip-agent review of the same fixture repo must behave differently. Suppress: 👎 makes the same hit a drop. Promote: `→ rule` plus promote enables a regex that still fires after the bootstrap rule is off.

## Sub-features

- `learn-harvest` records a succeeded harvest for the fixture remote before any review.
- `learn-bootstrap-rule` inserts a handwritten regex for `eval(__gegenlesen_probe__)`.
- `learn-review-one` reviews a probe file and shows one kept finding.
- `learn-suppress` records 👎, merge-intent no, Learn, then a second review with zero kept findings.
- `learn-promote` records `→ rule`, promotes that suggested regex, disables the bootstrap rule, then a new probe file still produces one kept finding.
- `learn-control` reviews a file without the token and shows zero findings.

## How to get to it (user POV)

- Nav `jobs` → open a succeeded job.
- Finding buttons `👍` `👎` `💬` `→ rule`.
- Copy `would you have merged this unread?` with `yes` / `no`.
- Button `learn` on the findings heading.
- Nav `learnings` for accept / dismiss.
- Nav `rules` → suggested rule → `promote`. List row `disable` on the bootstrap title.

## Driving it with drive.sh

Preconditions:

- Default launch (skip-agent, dummy key). Doctor is `ok`.
- Seeded rules left enabled. Do not delete them.
- Use a dedicated `VERIFY_RUN`. Suppress and promote conflict (one leaves the bootstrap on, the other disables it). Run them as two launches, or run suppress first and stop.
- Ledger has no regex create form. Bootstrap is `regex-rule-create` (POST `/api/rules`). Everything after that is a click or `gegenlesen review`.

- **Harvest.** Run `.agents/skills/verify-gegenlesen/drive.sh harvest`. Exit 0. First stdout line is a UUID. A later line is `succeeded`. `harvest-job.json` has `"status": "succeeded"`. This is a harvest job, not a review.
- **Bootstrap regex.** Run `.agents/skills/verify-gegenlesen/drive.sh regex-rule-create --id verify-bootstrap-probe --title "verify bootstrap probe" --pattern 'eval\(__gegenlesen_probe__\)' --message probe`. Status 201. Body `kind` is `deterministic`, `payload.checker` is `regex`, `enabled` is true.
- **Review one.** Run `.agents/skills/verify-gegenlesen/drive.sh cli-review --fresh --probe --label review-1`. Exit 0. `review-1-job.json` status `succeeded`, `risk.reasons` contains `reviewers_skipped`. Findings length 1, `judge_verdict` is `keep` (or omitted keep). File is `Sources/Probe.swift`. Shot `/jobs/<id>` with label `review-1-detail`. The finding title `verify bootstrap probe` and buttons `👎` `→ rule` are visible.
- **Suppress.** Click 👎: `.agents/skills/verify-gegenlesen/drive.sh job-thumb --down`. The 👎 button has class `on`. GET `/api/jobs/<id>/feedback` has `verdict` `disagree`. Click merge-intent no: `.agents/skills/verify-gegenlesen/drive.sh job-merge-intent --no`. Page copy `labeled would not merge unread`. GET job `risk.safe_unread` is false. Click Learn: `.agents/skills/verify-gegenlesen/drive.sh job-learn`. Learn job `succeeded` in `learn-job.json`. Second review: `.agents/skills/verify-gegenlesen/drive.sh cli-review --keep --probe --label review-2`. `review-2-job.json` has one finding, `judge_verdict` `drop`, `judge_rationale` `operator_disagree`. Kept count is 0. Shot `/jobs/<id>` with label `review-2-dropped`. Empty kept copy is acceptable; toggle `show dropped` to see the drop.
- **Promote (separate launch).** Harvest + bootstrap + `cli-review --fresh --probe --label review-1` as above. `.agents/skills/verify-gegenlesen/drive.sh job-should-be-rule`. Feedback `verdict` `should_be_rule` and `suggested_rule_id` set. `.agents/skills/verify-gegenlesen/drive.sh rule-promote --id <suggested_rule_id>`. GET that rule `provenance` `handwritten`, `enabled` true, `payload.checker` `regex`. `.agents/skills/verify-gegenlesen/drive.sh rule-disable --id verify-bootstrap-probe`. Bootstrap row button is `enable`. `.agents/skills/verify-gegenlesen/drive.sh cli-review --keep --advance-base --file Sources/Probe2.swift --content 'eval(__gegenlesen_probe__)' --label review-loud`. `review-loud-job.json` has one kept finding whose `rule_id` is the promoted id, not `verify-bootstrap-probe`, file `Sources/Probe2.swift`. `.agents/skills/verify-gegenlesen/drive.sh cli-review --keep --advance-base --file Sources/Clean.swift --content 'let x = 1' --label review-quiet`. `review-quiet-job.json` findings length 0.
- **Proof.** For suppress: `review-1-job.json`, `job-thumb-down` shot, merge-intent shot, `learn-job.json`, `review-2-job.json` with `operator_disagree`. For promote: `should-be-rule-after` shot, `rule-promoted.json`, `review-loud-job.json` vs `review-quiet-job.json`. A learn shot without a second review is not the loop.

## Gotchas

- Harvest is required before `gegenlesen review` (`harvest_required`). `cli-review` harvests once per launch (`harvested` in `instance.json`). `jobs-empty` must run before the first harvest or review.
- `--fresh` deletes the fixture repo and clears `harvested`. `--keep` reuses the remote `github.com/gegenlesen/verify-fixture` so suppressions stay repo-scoped. Pack base is `origin/main` at the first fixture commit; `--advance-base` moves that ref to `HEAD` so the next commit is the whole change-set.
- Skip-agent Learn still enqueues a mine job. Wait for that UUID, not the review id. Rules in `/learnings` still want thumbs from two jobs; `→ rule` is the one-job path and lands on `/rules`, not the inbox.
- `should_be_rule` on a one-line snippet drafts regex. Promote enables in place. Disable bootstrap by id `verify-bootstrap-probe`, not the promoted kebab of the finding title.
- 👎 suppresses by fingerprint in this repository only. A new `VERIFY_RUN` is a new SQLite and will not see the previous 👎.
- Merge-intent never suppresses. The suppress recipe still clicks `no` so the label is part of the loop.
- Default `cli-review` (no `--probe`) has no probe finding. Do not use it for this feature.
- A skip-agent job is not a full A/B review. Say so in the proof.
