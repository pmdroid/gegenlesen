#!/usr/bin/env bash
# Build, codesign, notarize, and package macOS (Darwin) gegenlesen binaries
# for GitHub Releases.
#
# CI only ships Linux Docker images. Darwin is built by hand on a Mac with a
# Developer ID. Gatekeeper needs notarization, not just codesign.
#
# Usage:
#   ./scripts/release-darwin.sh v0.1.1
#   ./scripts/release-darwin.sh v0.1.1 --upload
#   ./scripts/release-darwin.sh v0.1.1 --arch arm64
#   ./scripts/release-darwin.sh v0.1.1 --adhoc
#   ./scripts/release-darwin.sh v0.1.1 --skip-notarize
#   ./scripts/release-darwin.sh v0.1.1 --install
#
# One-time notary login (app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials gegenlesen-notarize \
#     --apple-id <apple-id> --team-id W363QN58YY
#
# Env:
#   CODESIGN_IDENTITY          Override identity
#   GEGENLESEN_SIGN_ADHOC=1    Same as --adhoc
#   NOTARY_KEYCHAIN_PROFILE    Default gegenlesen-notarize
#   APPLE_ID APPLE_TEAM_ID NOTARY_PASSWORD
#   NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER   App Store Connect API key
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=toolchain.sh
. "$ROOT/scripts/toolchain.sh"
gegenlesen_sync_build_dir "$ROOT"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

VERSION=""
ARCHS=()
UPLOAD=0
INSTALL=0
FORCE_ADHOC=0
SKIP_NOTARIZE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      sed -n '2,26p' "$0"
      exit 0
      ;;
    --upload) UPLOAD=1; shift ;;
    --install) INSTALL=1; shift ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch needs arm64 or x64"
      ARCHS+=("$2")
      shift 2
      ;;
    v*)
      VERSION="$1"
      shift
      ;;
    *)
      die "unknown arg: $1 (pass version like v0.1.1)"
      ;;
  esac
done

[[ -n "$VERSION" ]] || die "usage: $0 v0.1.1 [--upload] [--install] [--arch arm64|x64] [--adhoc] [--skip-notarize]"
case "$VERSION" in
  v*) ;;
  *) VERSION="v${VERSION}" ;;
esac
VERSION_NOPREFIX="${VERSION#v}"

[[ "$(uname -s)" == "Darwin" ]] || die "must run on macOS"

if [[ ${#ARCHS[@]} -eq 0 ]]; then
  ARCHS=(arm64 x64)
fi

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ "$FORCE_ADHOC" -eq 1 || "${GEGENLESEN_SIGN_ADHOC:-}" == "1" ]]; then
  IDENTITY="-"
elif [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' \
      | head -1
  )"
  if [[ -z "$IDENTITY" ]]; then
    log "no Developer ID found, using ad-hoc sign (-)"
    IDENTITY="-"
  fi
fi

NOTARIZE=0
if [[ "$IDENTITY" != "-" && "$SKIP_NOTARIZE" -eq 0 ]]; then
  NOTARIZE=1
fi

if [[ "$IDENTITY" == "-" ]]; then
  log "signing: ad-hoc (Gatekeeper will block downloads)"
else
  log "signing: $IDENTITY"
  if [[ "$NOTARIZE" -eq 1 ]]; then
    log "notarize: yes"
  else
    log "notarize: skipped"
  fi
fi

sign_bin() {
  local bin="$1"
  local ident="$2"
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --identifier "$ident" --sign - "$bin"
  else
    codesign --force --options runtime --timestamp \
      --identifier "$ident" \
      --sign "$IDENTITY" \
      "$bin"
  fi
  codesign --verify --verbose=2 "$bin"
}

assert_portable_links() {
  local bin="$1"
  local bad
  bad="$(otool -L "$bin" | awk '/^\t/ {print $1}' | grep -E '^/opt/homebrew|^/usr/local/opt' || true)"
  if [[ -n "$bad" ]]; then
    die "$bin links non-system dylibs (would break other Macs):
$bad"
  fi
}

swift_arch_for() {
  case "$1" in
    arm64|aarch64) echo arm64 ;;
    x64|amd64|x86_64) echo x86_64 ;;
    *) die "unsupported --arch $1 (use arm64 or x64)" ;;
  esac
}

darwin_suffix_for() {
  case "$1" in
    arm64|aarch64) echo darwin-arm64 ;;
    x64|amd64|x86_64) echo darwin-x64 ;;
    *) die "unsupported --arch $1 (use arm64 or x64)" ;;
  esac
}

notary_auth() {
  if [[ -n "${NOTARY_KEY:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
    echo --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    echo --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$NOTARY_PASSWORD"
  else
    echo --keychain-profile "${NOTARY_KEYCHAIN_PROFILE:-gegenlesen-notarize}"
  fi
}

ensure_notary() {
  # shellcheck disable=SC2046
  if xcrun notarytool history $(notary_auth) >/dev/null 2>&1; then
    return 0
  fi
  cat >&2 <<EOF
error: notary credentials missing. Gatekeeper will keep blocking downloads.

One-time:
  xcrun notarytool store-credentials ${NOTARY_KEYCHAIN_PROFILE:-gegenlesen-notarize} \\
    --apple-id <apple-id> --team-id W363QN58YY

Create an app-specific password at https://appleid.apple.com (Sign-In and Security).
Or set APPLE_ID, APPLE_TEAM_ID, NOTARY_PASSWORD, or an App Store Connect API key
(NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER).

Pass --skip-notarize only for a local ad-hoc experiment.
EOF
  exit 1
}

notarize_stage() {
  local stage="$1"
  local name="$2"
  local zip="dist/${name}.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$stage" "$zip"
  log "notarize ${name}.zip"
  # shellcheck disable=SC2046
  xcrun notarytool submit "$zip" $(notary_auth) --wait --timeout 20m
  rm -f "$zip"
  # Naked Mach-O cannot be stapled. The ticket is on Apple's servers, keyed
  # by CDHash. First launch needs network so Gatekeeper can look it up.
}

stage_shared() {
  local stage="$1"
  mkdir -p "$stage/frontend" "$stage/config" "$stage/docker"
  cp -R "$ROOT/frontend/dist" "$stage/frontend/dist"
  cp -R "$ROOT/rules" "$stage/rules"
  cp -R "$ROOT/schemas" "$stage/schemas"
  cp -R "$ROOT/docker/opencode-runner" "$stage/docker/opencode-runner"
  if [[ -d "$ROOT/skills" ]]; then
    cp -R "$ROOT/skills" "$stage/skills"
  fi
  cp "$ROOT/config/gegenlesen.example.json" "$stage/config/gegenlesen.example.json"
}

mkdir -p dist

python3 - "$VERSION_NOPREFIX" <<'PY'
import pathlib, re, sys
path = pathlib.Path("Sources/GegenlesenAPI/Version.swift")
text = path.read_text()
next_text, n = re.subn(
    r'static let current = "[^"]+"',
    f'static let current = "{sys.argv[1]}"',
    text,
    count=1,
)
if n != 1:
    raise SystemExit("could not stamp Sources/GegenlesenAPI/Version.swift")
path.write_text(next_text)
PY

if [[ "$NOTARIZE" -eq 1 ]]; then
  ensure_notary
fi

log "frontend"
if [[ ! -d frontend/node_modules ]]; then
  (cd frontend && npm ci)
fi
(cd frontend && npm run build)

SUMS_FILE="dist/SHA256SUMS-darwin-${VERSION}"
: >"$SUMS_FILE"

for arch in "${ARCHS[@]}"; do
  swift_arch="$(swift_arch_for "$arch")"
  suffix="$(darwin_suffix_for "$arch")"
  name="gegenlesen-${VERSION}-${suffix}"
  stage="dist/${name}"

  if [[ "$swift_arch" == "x86_64" ]]; then
    arch -x86_64 /usr/bin/true >/dev/null 2>&1 \
      || die "x86_64 build needs Rosetta (softwareupdate --install-rosetta)"
  fi

  log "compile ${name} (swift --arch ${swift_arch})"
  ./scripts/swift build -c release --arch "$swift_arch" --product GegenlesenAPI
  ./scripts/swift build -c release --arch "$swift_arch" --product gegenlesen
  bin_dir="$(./scripts/swift build -c release --arch "$swift_arch" --product GegenlesenAPI --show-bin-path)"
  [[ -x "${bin_dir}/GegenlesenAPI" && -x "${bin_dir}/gegenlesen" ]] \
    || die "missing release binaries in ${bin_dir}"

  rm -rf "$stage"
  mkdir -p "$stage"
  install -m 0755 "${bin_dir}/GegenlesenAPI" "$stage/GegenlesenAPI"
  install -m 0755 "${bin_dir}/gegenlesen" "$stage/gegenlesen"
  strip -x "$stage/GegenlesenAPI" "$stage/gegenlesen" 2>/dev/null || true
  stage_shared "$stage"

  assert_portable_links "$stage/GegenlesenAPI"
  assert_portable_links "$stage/gegenlesen"

  log "codesign ${name}"
  sign_bin "$stage/GegenlesenAPI" "dev.gegenlesen.api"
  sign_bin "$stage/gegenlesen" "dev.gegenlesen.cli"

  if [[ "$NOTARIZE" -eq 1 ]]; then
    notarize_stage "$stage" "$name"
  fi

  log "tar ${name}.tar.gz"
  tar -C dist -czf "dist/${name}.tar.gz" "${name}"
  (cd dist && shasum -a 256 "${name}.tar.gz") >>"$SUMS_FILE"
done

log "checksums → ${SUMS_FILE}"
cat "$SUMS_FILE"

if [[ "$INSTALL" -eq 1 ]]; then
  machine="$(uname -m)"
  case "$machine" in
    arm64) inst_suffix="darwin-arm64" ;;
    x86_64) inst_suffix="darwin-x64" ;;
    *) die "unknown machine arch: $machine" ;;
  esac
  stage="dist/gegenlesen-${VERSION}-${inst_suffix}"
  [[ -x "$stage/gegenlesen" && -x "$stage/GegenlesenAPI" ]] || die "missing $stage for --install"
  share="$HOME/.local/share/gegenlesen"
  bindir="$HOME/.local/bin"
  mkdir -p "$share" "$bindir"
  rm -rf "$share"
  mkdir -p "$share"
  cp -R "$stage/." "$share/"
  ln -sfn "$share/gegenlesen" "$bindir/gegenlesen"
  ln -sfn "$share/GegenlesenAPI" "$bindir/GegenlesenAPI"
  sign_bin "$share/gegenlesen" "dev.gegenlesen.cli"
  sign_bin "$share/GegenlesenAPI" "dev.gegenlesen.api"
  log "installed → ~/.local/bin/gegenlesen  (+ GegenlesenAPI)"
  log "layout     → ~/.local/share/gegenlesen"
  log "run: GegenlesenAPI serve --data-dir \"\$HOME/gegenlesen-data\""
fi

if [[ "$UPLOAD" -eq 1 ]]; then
  command -v gh >/dev/null || die "gh CLI required for --upload"
  files=()
  for arch in "${ARCHS[@]}"; do
    suffix="$(darwin_suffix_for "$arch")"
    files+=("dist/gegenlesen-${VERSION}-${suffix}.tar.gz")
  done
  files+=("$SUMS_FILE")
  log "upload to release ${VERSION}"
  gh release upload "$VERSION" "${files[@]}" --clobber
  log "uploaded to https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/${VERSION}"
fi

log "done"
echo ""
echo "Artifacts:"
ls -la dist/gegenlesen-"${VERSION}"-darwin-*.tar.gz "$SUMS_FILE" 2>/dev/null || true
echo ""
if [[ "$NOTARIZE" -eq 1 ]]; then
  echo "Notarized. First launch of a quarantined download needs network so Gatekeeper can fetch the ticket."
fi
