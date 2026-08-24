---
title: How a review works
description: Pack, identify, deterministic checks, two reviewers, one judge.
order: 3
---

```
gegenlesen review
  → unpack (libarchive, not tar -xf)
  → identify the git range
  → load matching rules (handwritten + mined, enabled only)
  → deterministic checks on the host
  → OpenCode reviewers A and B in parallel
  → judge keep / drop / downgrade
  → persist findings
```

## Scope

| Scope | Upload | What gets read |
| --- | --- | --- |
| Full change | Tarball from `gegenlesen pack` | The whole identified diff |
| Incremental | New tarball + `parent_job_id` of a succeeded job | New hunks only |

The pack embeds `.gegenlesen/diff.patch` and, when it fits, a thin git bundle.

## Models

Set `OPENROUTER_API_KEY`. There is no Anthropic path.

| Slot | Default |
| --- | --- |
| Reviewer A | `openrouter/deepseek/deepseek-v4-flash` |
| Reviewer B | `openrouter/google/gemini-3.7-flash` |
| Findings judge | `openrouter/openai/gpt-5.6-terra` |

Both reviewers always run when there is new work. One valid findings file is enough to continue. Zero valid files fails the job.

Gemini Flash sometimes returns `PROHIBITED_CONTENT` on hop, tunnel, and VNC code. The other slot can still land findings.

## Findings contract

Reviewers write `.gegenlesen/findings-model_a.json` and `.gegenlesen/findings-model_b.json`. The judge writes `.gegenlesen/judge.json`. The host is the source of truth after persist.

The findings judge defaults to keep. The host still drops a finding when the cited lines do not support it.

## Deterministic checks

Regex, deny-lists, sibling-test files, optional sandbox `command`, and an OpenAPI break check run on the host or in the runner **without** OpenCode and **without** provider keys. They never skip the reviewers by themselves.
