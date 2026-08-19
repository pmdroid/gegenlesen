---
title: Learn
description: How thumbs, comments, and the miner become suggested rules.
---

Learn is not part of the review path. A review can write an architecture draft. It does not invent rules from findings.

## When it runs

- Button on the job page (`POST /api/jobs/:id/learn`)
- `gegenlesen` has no separate learn CLI yet. Use the API or the button.
- `LearnSweepJob` on `limits.learn_interval_minutes` (default 15, `0` turns the sweep off)

## What becomes a candidate

From the job, only findings you 👍 or marked `should_be_rule`. Judge-dropped findings never become suggestions.

## Pipeline

1. Host filter (endorsement only)
2. Miner uses reviewer A (DeepSeek Flash). Cheap pass.
3. Suggestion judge (Terra) defaults to **drop**. A keep may include `rewrite.title` and `rewrite.body`.
4. Kept rules upsert as **disabled**. Context notes land in the learnings inbox.

Nothing auto-enables.

The original miner title and body stay in the learning payload as `original_title` / `original_body` when Terra rewrites.
