# Shared by other scripts. Prefer Xcode's Swift so CLT 6.2 cannot
# reuse modules compiled by Xcode 6.3 (or the reverse).
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

gegenlesen_swift_version() {
  swift --version 2>/dev/null | head -n 1
}

gegenlesen_sync_build_dir() {
  local root="${1:-.}"
  local marker="$root/.build/gegenlesen-swift-version"
  local current
  current="$(gegenlesen_swift_version)"
  if [ -z "$current" ]; then
    return 0
  fi
  if [ -f "$marker" ] && [ "$(cat "$marker")" != "$current" ]; then
    rm -rf "$root/.build"
  fi
  mkdir -p "$root/.build"
  printf '%s\n' "$current" >"$marker"
}
