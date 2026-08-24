---
title: Ledger
description: The admin UI. Jobs, findings, rules, context, learnings.
order: 4
---

Ledger is the React app under `frontend/`. It talks to `/api` on the same origin in Vite (proxied to `:8080`).

It does not start reviews. Use `gegenlesen review` or `POST /api/jobs`.

## Pages

| Path | What |
| --- | --- |
| `/` | Job list |
| `/jobs/:id` | Findings, events, thumbs, comments, learn button |
| `/rules` | Handwritten and mined rules |
| `/context` | Operator notes |
| `/learnings` | Suggested rules and context, accept / dismiss / restore, accept vs dismiss rate per kind |

## Feedback

Thumbs and comments store on the finding. They do not mint a rule by themselves.

Show dropped to 👍 a judge-drop. That records learn intent; it does not restore the finding.

`should_be_rule` immediately drafts a **disabled** rule. Everything else waits for a learn job.

## Rules

Two sources, two kinds.

| | Deterministic | Semantic |
| --- | --- | --- |
| Handwritten | YAML in the UI or `rules/` | Natural-language rule |
| Mined | From a historical PR corpus, disabled until promoted | Same, retrieved by glob + FTS5 |

Promoting a mined rule copies it to a handwritten id. Enabling is a separate switch.
