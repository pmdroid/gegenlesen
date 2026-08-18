#!/bin/sh
# usage: pack-repo.sh [base-ref] > change.tar.gz
set -eu
BASE_REF=${1:-}
HEAD=$(git rev-parse HEAD)
if [ -n "$BASE_REF" ]; then
  BASE=$(git rev-parse "$BASE_REF")
else
  BASE=$(git merge-base origin/main HEAD 2>/dev/null \
      || git merge-base main HEAD 2>/dev/null \
      || git rev-parse HEAD^ 2>/dev/null \
      || git rev-parse HEAD)
fi
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/.meister"
git archive HEAD | tar -x -C "$WORKDIR"
printf '%s' "$BASE" > "$WORKDIR/.meister/base_sha"
printf '%s' "$HEAD" > "$WORKDIR/.meister/head_sha"

# Required change-set. Do not `|| true`.
git diff --no-color --find-renames "$BASE" "$HEAD" \
  > "$WORKDIR/.meister/diff.patch"

# Optional self-contained bundle (both tips, no A..B prerequisite).
# Omit if git fails or the file exceeds 40 MiB — the diff is enough for full review.
if git bundle create "$WORKDIR/.meister/history.bundle" "$BASE" "$HEAD" 2>/dev/null; then
  size=$(wc -c < "$WORKDIR/.meister/history.bundle")
  if [ "$size" -gt 41943040 ]; then
    rm -f "$WORKDIR/.meister/history.bundle"
  fi
else
  rm -f "$WORKDIR/.meister/history.bundle"
fi

if [ ! -f "$WORKDIR/.meister/diff.patch" ]; then
  echo "pack-repo.sh: git diff did not produce .meister/diff.patch" >&2
  exit 1
fi
if [ ! -s "$WORKDIR/.meister/diff.patch" ] \
   && [ ! -f "$WORKDIR/.meister/history.bundle" ] \
   && [ "$BASE" != "$HEAD" ]; then
  echo "pack-repo.sh: empty diff and no usable bundle" >&2
  exit 1
fi

COPYFILE_DISABLE=1 tar -czf - \
  --exclude='node_modules' --exclude='.build' --exclude='dist' \
  --exclude='target' --exclude='var' \
  -C "$WORKDIR" .
