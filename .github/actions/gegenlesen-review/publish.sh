#!/usr/bin/env bash
set -euo pipefail

json="${GEGENLESEN_JSON:?GEGENLESEN_JSON is required}"
mode_in="${GEGENLESEN_PUBLISH_MODE:-auto}"

if ! command -v jq >/dev/null || ! command -v gh >/dev/null; then
  echo "publish.sh needs jq and gh on PATH" >&2
  exit 1
fi
if [ ! -s "$json" ]; then
  echo "missing review json: $json" >&2
  exit 1
fi

status=$(jq -r '.status // empty' "$json")
verdict=$(jq -r '.risk.verdict // empty' "$json")
host_mode=$(jq -r '.risk.mode // "shadow"' "$json")
reviewed_sha=$(jq -r '.head_sha // empty' "$json")
job_id=$(jq -r '.job_id // empty' "$json")
markdown=$(jq -r '.markdown // empty' "$json")

mode="$mode_in"
if [ "$mode" = "auto" ]; then
  mode="$host_mode"
fi
if [ "$mode" = "off" ]; then
  mode="shadow"
fi

if [ -z "${PR_NUMBER:-}" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
  PR_NUMBER=$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")
fi
if [ -z "${PR_NUMBER:-}" ]; then
  echo "PR_NUMBER is not set and the event payload has no pull_request.number" >&2
  exit 1
fi
if [ -z "${GITHUB_REPOSITORY:-}" ]; then
  echo "GITHUB_REPOSITORY is required" >&2
  exit 1
fi
if [ -z "$markdown" ]; then
  echo "review json has no markdown" >&2
  exit 1
fi

comment_id=$(
  gh api --paginate "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" \
    --jq '.[] | select(.body | contains("<!-- gegenlesen-review -->")) | .id' \
    | head -n 1
)
payload=$(jq -n --arg body "$markdown" '{body:$body}')
if [ -n "$comment_id" ]; then
  echo "$payload" | gh api --method PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" --input -
else
  echo "$payload" | gh api --method POST "repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments" --input -
fi

live_sha=$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq .head.sha)

approved=0
if [ "$mode" = "enforce" ] && [ "$status" = "succeeded" ] && [ "$verdict" = "auto_approve" ]; then
  if [ -n "$reviewed_sha" ] && [ "$reviewed_sha" = "$live_sha" ]; then
    gh pr review "$PR_NUMBER" --repo "$GITHUB_REPOSITORY" --approve \
      --body "gegenlesen auto-approved ${reviewed_sha}. Approve is not merge. A human still has to satisfy required reviewers."
    approved=1
  else
    echo "skipping approve: reviewed ${reviewed_sha:-none} live ${live_sha:-none}" >&2
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "verdict=${verdict}"
    echo "mode=${mode}"
    echo "job-id=${job_id}"
    echo "approved=${approved}"
  } >> "$GITHUB_OUTPUT"
fi

echo "gegenlesen job=${job_id} status=${status} verdict=${verdict} mode=${mode} approved=${approved}"

if [ "$status" != "succeeded" ]; then
  exit 1
fi
if [ "$mode" = "enforce" ] && [ "$verdict" != "auto_approve" ]; then
  exit 1
fi
exit 0
