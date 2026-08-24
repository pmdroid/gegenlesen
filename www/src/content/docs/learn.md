---
title: Learn
description: How thumbs, comments, and the miner become suggested rules.
order: 5
---

Learn is not part of the review path. A review can write an architecture draft. It does not invent rules from findings.

`gegenlesen harvest` is a separate first-run pass over a packed tree. It scans lint configs as suppressions, Flash drafts cited conventions, Terra drops most of them, and Ledger gets disabled drafts tagged `source: harvest`. If the miner or suggestion judge fails, harvest does not write the ordinary inbox; drafts go to `needs_rejudge` (or the job fails with `harvest_judge_failed`). Context notes are capped at 2000 characters. Whole README.md / docs/*.md dumps are dropped. Nothing auto-enables.

## When it runs

- Button on the job page (`POST /api/jobs/:id/learn`)
- `gegenlesen` has no separate learn CLI yet. Use the API or the button.
- `LearnSweepJob` on `limits.learn_interval_minutes` (default 15, `0` turns the sweep off)

## What becomes a candidate

From the job, findings you 👍 or marked `should_be_rule`, including judge-dropped ones. Endorsement is learn eligibility only — dropped findings stay out of the kept inbox. Suggestion judge still default-drops.

A *rule* lands in the inbox only after ≥2 distinct jobs endorsed the same normalized title. Context notes can land after one job (still after the suggestion judge). Nothing auto-enables.

Dismissing a learning stores an optional reason (`duplicate`, `already_covered`, `too_specific`, `not_a_rule`, `other`) plus a comment. That title-hash stays out of the inbox until you restore the dismiss.

A job-level merge-intent label (would you have merged unread?) also enqueues learn. Would-merge is a positive exemplar for that class of diff. Would-not treats kept errors as mine-worthy even without thumbs. Auto-approve then "no" is the strongest would-not. The label never auto-drops a finding and never enables a rule.

## Pipeline

1. Host filter (this-job endorsement, or would-not-merge kept errors)
2. Miner uses reviewer A (DeepSeek Flash). Cheap pass.
3. Suggestion judge (Terra) defaults to **drop**. A keep may include `rewrite.title` and `rewrite.body`.
4. Kept **rules** upsert as **disabled** only after two distinct-job endorsements. Context notes may inbox after one job.

Nothing auto-enables.

The original miner title and body stay in the learning payload as `original_title` / `original_body` when Terra rewrites.
