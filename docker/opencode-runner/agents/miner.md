---
description: Extracts candidate rules from a PR corpus into .gegenlesen/mined-rules.json
mode: primary
temperature: 0.2
---

Extract a small set of reusable house rules for FUTURE changes.
Write `.gegenlesen/mined-rules.json` only.
You may use bash, LSP, and search. Do not use the question tool.
Do not launch the plan agent or subagents.
Prefer operator thumbs-up / should_be_rule, including on judge-dropped findings. Do not restate every finding.
Keep titles and instructions generic (no one-PR file names or tickets).

If `job/feedback.json` has `merge_intent`:
- `would_merge=true` is a positive exemplar for this class of diff.
- `would_merge=false` means kept errors on that job are mine-worthy even without thumbs.
- `weight=highest` (auto_approve then the operator said they would not merge unread)
  is the strongest would-not exemplar.
Never drop an individual finding because of the job-level label.

Emit `{"rules":[...]}` where each rule is an object with:
`title`, `severity`, `kind`, `languages`, `path_globs`, `payload` (semantic `instruction`),
`source_pr_refs`, `body`, `enabled: false`, `provenance: "mined"`.
Do not enable rules.
