---
title: GitHub Action
description: Review a PR from a self-hosted runner, comment, optionally approve.
order: 8
---

A GitHub-hosted runner joins your tailnet with the Tailscale GitHub Action, packs the PR, posts the job to gegenlesen over MagicDNS, then talks to GitHub with `GITHUB_TOKEN`. There is no webhook into the API and no Check Runs API. The workflow job is the pending / pass / fail status.

The CLI still starts reviews. The Action is another CLI caller.

## What it posts

After judge merge the host writes `risk.verdict`. The Action does not re-score.

- `needs_human`: upsert one sticky comment (HTML marker `<!-- gegenlesen-review -->`) with the top findings, `file:line` links, and the veto reasons. In **enforce**, the job fails so a required check blocks merge. It does not `REQUEST_CHANGES`.
- `auto_approve` in **enforce**: `gh pr review --approve` for the exact head SHA that was reviewed. Approve is not merge. Keep a human on required reviewers. Turn on dismiss stale reviews.
- **shadow** (default host `risk.mode`): comment still lands, the check stays green, no approval.

If the PR head moved between pack and approve, the Action skips the approval and lets the next `synchronize` run handle it.

## Tailscale

GitHub-hosted runners are not on your tailnet. Add `tailscale/github-action` before gegenlesen so the job gets an ephemeral node and MagicDNS works.

1. In the admin console, create an [OAuth client](https://tailscale.com/kb/1215/oauth-clients) with the `auth_keys` scope. Restrict it to a tag such as `tag:ci`.
2. Store `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET` as GitHub Actions secrets.
3. ACL: `tag:ci` must be allowed to talk to the gegenlesen node on port 8080.
4. Point `gegenlesen-url` at the node's MagicDNS name. The example uses `http://box.tail9f3a.ts.net:8080`. That is a dummy. Use your own.
5. Because that is not loopback, start the API with `GEGENLESEN_ALLOW_REMOTE=1` and bind on the Tailscale interface (or `0.0.0.0`).

If the runner is already a Tailscale node, skip the Tailscale step.

Fork PRs are refused. `jq`, `gh`, and `gegenlesen` need to be on PATH.

This repository's workflow is off until you set the repo variable `GEGENLESEN_ENABLED=true`. Set `GEGENLESEN_URL` to your MagicDNS URL. Optional `GEGENLESEN_RUNNER` overrides the runner label.

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
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4
      - name: Tailscale
        uses: tailscale/github-action@v4
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci
      - uses: pmdroid/gegenlesen/.github/actions/gegenlesen-review@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          mode: auto
          gegenlesen-url: http://box.tail9f3a.ts.net:8080
```

`mode: auto` follows the job's `risk.mode`. `shadow` and `enforce` override it for the publisher only. The host veto is still the verdict.

CLI bits the Action uses:

```bash
gegenlesen review --format json --timeout 3600
```

`--require-auto-approve` remains the no-GitHub CI gate. The Action does not pass it. It reads `risk.verdict` from the JSON and decides the check exit itself.
