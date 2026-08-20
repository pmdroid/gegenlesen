---
title: GitHub Action
description: Review a PR from a self-hosted runner, comment, optionally approve.
order: 8
---

gegenlesen stays on `127.0.0.1`. A GitHub Action on a runner that shares that machine packs the PR, waits for the job, then talks to GitHub with `GITHUB_TOKEN`. There is no webhook into the API and no Check Runs API. The workflow job is the pending / pass / fail status.

The CLI still starts reviews. The Action is another CLI caller.

## What it posts

After judge merge the host writes `risk.verdict`. The Action does not re-score.

- `needs_human`: upsert one sticky comment (HTML marker `<!-- gegenlesen-review -->`) with the top findings, `file:line` links, and the veto reasons. In **enforce**, the job fails so a required check blocks merge. It does not `REQUEST_CHANGES`.
- `auto_approve` in **enforce**: `gh pr review --approve` for the exact head SHA that was reviewed. Approve is not merge. Keep a human on required reviewers. Turn on dismiss stale reviews.
- **shadow** (default host `risk.mode`): comment still lands, the check stays green, no approval.

If the PR head moved between pack and approve, the Action skips the approval and lets the next `synchronize` run handle it.

## Runner

The runner has to reach `http://127.0.0.1:8080`. That means it lives on the gegenlesen host (or you name a loopback exception, which this repo does not). Fork PRs are refused. `jq` and `gh` need to be on PATH, and `gegenlesen` too.

This repository's workflow is off until you set the repo variable `GEGENLESEN_ENABLED=true`. Optional `GEGENLESEN_RUNNER` overrides the runner label (default `self-hosted`).

Org settings that bite:

- Allow GitHub Actions to create and approve pull requests, or enforce-mode approve will 403.
- Do not let `github-actions[bot]` count toward required reviewers. Anyone who can edit the workflow could otherwise self-approve.

## Workflow

```yaml
name: gegenlesen
on:
  pull_request:
    types: [opened, synchronize, reopened]
permissions:
  contents: read
  pull-requests: write
concurrency:
  group: gegenlesen-${{ github.repository }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  review:
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: self-hosted
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - uses: pmdroid/gegenlesen/.github/actions/gegenlesen-review@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          mode: auto
```

`mode: auto` follows the job's `risk.mode`. `shadow` and `enforce` override it for the publisher only. The host veto is still the verdict.

CLI bits the Action uses:

```bash
gegenlesen review --format json --timeout 3600
```

`--require-auto-approve` remains the no-GitHub CI gate. The Action does not pass it. It reads `risk.verdict` from the JSON and decides the check exit itself.
