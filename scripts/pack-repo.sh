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
mkdir -p "$WORKDIR/.gegenlesen"
git archive HEAD | tar -x -C "$WORKDIR"
printf '%s' "$BASE" > "$WORKDIR/.gegenlesen/base_sha"
printf '%s' "$HEAD" > "$WORKDIR/.gegenlesen/head_sha"

# Empty patch is allowed only when BASE equals HEAD, or a usable bundle is kept.
git diff --no-color --find-renames "$BASE" "$HEAD" \
  > "$WORKDIR/.gegenlesen/diff.patch"

# Optional bundle; drop if git fails or the file exceeds 40 MiB.
if git bundle create "$WORKDIR/.gegenlesen/history.bundle" "$BASE" "$HEAD" 2>/dev/null; then
  size=$(wc -c < "$WORKDIR/.gegenlesen/history.bundle")
  if [ "$size" -gt 41943040 ]; then
    rm -f "$WORKDIR/.gegenlesen/history.bundle"
  fi
else
  rm -f "$WORKDIR/.gegenlesen/history.bundle"
fi

if [ ! -f "$WORKDIR/.gegenlesen/diff.patch" ]; then
  echo "pack-repo.sh: git diff did not produce .gegenlesen/diff.patch" >&2
  exit 1
fi
if [ ! -s "$WORKDIR/.gegenlesen/diff.patch" ] \
   && [ ! -f "$WORKDIR/.gegenlesen/history.bundle" ] \
   && [ "$BASE" != "$HEAD" ]; then
  echo "pack-repo.sh: empty diff and no usable bundle" >&2
  exit 1
fi

COPYFILE_DISABLE=1 tar -czf - \
  --exclude='node_modules' --exclude='.build' --exclude='dist' \
  --exclude='target' --exclude='var' \
  -C "$WORKDIR" .
