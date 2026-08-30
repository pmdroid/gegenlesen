#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${GEGENLESEN_SPIKE_IMAGE:-gegenlesen/opencode-runner:0.1.0}"
MODEL="${GEGENLESEN_SPIKE_MODEL:-opencode/nemotron-3.5-lightning-free}"
TIMEOUT_SEC="${GEGENLESEN_SPIKE_TIMEOUT_SEC:-900}"
LOG_LEVEL="${GEGENLESEN_SPIKE_LOG_LEVEL:-WARN}"
NETWORK="gegenlesen-egress"
NAME="gegenlesen-acp-spike-$$"

PROVIDER_KEYS=()
for key in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY OPENCODE_API_KEY; do
  if [[ -n "${!key:-}" ]]; then
    PROVIDER_KEYS+=(-e "$key")
  fi
done
if [[ ${#PROVIDER_KEYS[@]} -eq 0 ]]; then
  echo "set at least one provider API key (agent auth is env-only): OPENCODE_API_KEY, OPENROUTER_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "runner image not found: $IMAGE (run ./scripts/build-runner.sh first)" >&2
  exit 1
fi

SPIKE_DIR="${GEGENLESEN_SPIKE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/gegenlesen-acp-spike.XXXXXX")}"
WORKSPACE="$SPIKE_DIR/workspace"
SEED="$SPIKE_DIR/opencode"
TRANSCRIPT="$SPIKE_DIR/transcript.jsonl"
rm -rf "$WORKSPACE" "$SEED"
mkdir -p "$WORKSPACE/.gegenlesen" "$WORKSPACE/src" "$SEED"

cp "$ROOT/docker/opencode-runner/opencode.json" "$SEED/opencode.json"
cp -R "$ROOT/docker/opencode-runner/agents" "$SEED/agents"

cat > "$WORKSPACE/src/token_cache.py" <<'EOF'
import json
import urllib.request

CACHE = {}


def fetch_token(url, retries=3):
    for _ in range(retries):
        try:
            with urllib.request.urlopen(url) as response:
                body = json.loads(response.read())
            return body["token"]
        except Exception:
            pass
    return None


def remember(user, scopes=[]):
    scopes.append("default")
    CACHE[user] = scopes
    return scopes
EOF

cat > "$WORKSPACE/.gegenlesen/prompt.md" <<'EOF'
# Review job

Review the change described in `.gegenlesen/diff.patch`. The changed files are
listed in `.gegenlesen/files.json` and the rules to apply are in
`.gegenlesen/rules.json`.

Slot path: write your findings to `.gegenlesen/findings.json` as a JSON object:

```json
{"findings": [{"rule_id": "no-swallowed-exceptions", "severity": "warning", "title": "...", "message": "...", "file_path": "src/token_cache.py", "start_line": 1, "end_line": 1, "snippet": "..."}]}
```

`severity` is one of `info`, `warning`, `error`. `rule_id` is null for defects
not covered by a rule. `snippet` must appear verbatim at `file_path`
`[start_line, end_line]`. If nothing is real, write `{"findings":[]}`.
EOF

cat > "$WORKSPACE/.gegenlesen/rules.json" <<'EOF'
[
  {
    "id": "no-swallowed-exceptions",
    "title": "Do not swallow exceptions",
    "description": "except blocks must not silently discard errors; log or re-raise."
  },
  {
    "id": "no-mutable-default-args",
    "title": "No mutable default arguments",
    "description": "Python function defaults must not be mutable objects."
  }
]
EOF

cat > "$WORKSPACE/.gegenlesen/files.json" <<'EOF'
["src/token_cache.py"]
EOF

cat > "$WORKSPACE/.gegenlesen/diff.patch" <<'EOF'
diff --git a/src/token_cache.py b/src/token_cache.py
new file mode 100644
--- /dev/null
+++ b/src/token_cache.py
@@ -0,0 +1,22 @@
+import json
+import urllib.request
+
+CACHE = {}
+
+
+def fetch_token(url, retries=3):
+    for _ in range(retries):
+        try:
+            with urllib.request.urlopen(url) as response:
+                body = json.loads(response.read())
+            return body["token"]
+        except Exception:
+            pass
+    return None
+
+
+def remember(user, scopes=[]):
+    scopes.append("default")
+    CACHE[user] = scopes
+    return scopes
EOF

CONFIG_CONTENT="$(node -e '
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
config.model = process.argv[2];
config.default_agent = "reviewer";
process.stdout.write(JSON.stringify(config));
' "$SEED/opencode.json" "$MODEL")"

PERMISSION="${GEGENLESEN_SPIKE_PERMISSION:-$(node -e '
const fs = require("node:fs");
const config = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
process.stdout.write(JSON.stringify(config.permission));
' "$SEED/opencode.json")}"

docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "workspace:  $WORKSPACE" >&2
echo "transcript: $TRANSCRIPT" >&2
echo "image:      $IMAGE" >&2
echo "model:      $MODEL" >&2

node "$ROOT/scripts/spike-acp-client.mjs" \
  --prompt-file "$WORKSPACE/.gegenlesen/prompt.md" \
  --prompt-uri "file:///workspace/.gegenlesen/prompt.md" \
  --transcript "$TRANSCRIPT" \
  --timeout-sec "$TIMEOUT_SEC" \
  -- \
  docker run --rm -i --name "$NAME" \
  --network "$NETWORK" \
  --workdir /workspace \
  --user 1000:1000 \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,uid=1000,gid=1000,size=512m \
  --tmpfs /home/gegenlesen/.local:rw,nosuid,nodev,uid=1000,gid=1000,size=256m \
  --tmpfs /home/gegenlesen/.cache:rw,nosuid,nodev,uid=1000,gid=1000,size=64m \
  --tmpfs /home/gegenlesen/.config/opencode:rw,nosuid,nodev,uid=1000,gid=1000,size=64m \
  --tmpfs /home/gegenlesen/.config/opencode-state:rw,nosuid,nodev,uid=1000,gid=1000,size=64m \
  --mount "type=bind,src=$WORKSPACE,dst=/workspace" \
  --mount "type=bind,src=$SEED,dst=/opt/gegenlesen/opencode,readonly" \
  --cpus 2 \
  --memory 4g \
  --pids-limit 256 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --ulimit nproc=256:256 \
  --ulimit nofile=1024:1024 \
  "${PROVIDER_KEYS[@]}" \
  -e HOME=/home/gegenlesen \
  -e XDG_CACHE_HOME=/home/gegenlesen/.cache \
  -e OPENCODE_DISABLE_AUTOUPDATE=true \
  -e OPENCODE_AUTO_SHARE=false \
  -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
  -e OPENCODE_DISABLE_CLAUDE_CODE=true \
  -e OPENCODE_EXPERIMENTAL_LSP_TOOL=true \
  -e OPENCODE_CONFIG=/home/gegenlesen/.config/opencode/opencode.json \
  -e OPENCODE_CONFIG_CONTENT="$CONFIG_CONTENT" \
  -e OPENCODE_PERMISSION="$PERMISSION" \
  "$IMAGE" \
  /bin/sh -c 'cp -a /opt/gegenlesen/opencode/. /home/gegenlesen/.config/opencode/ && exec "$@"' opencode \
  opencode acp --print-logs --log-level "$LOG_LEVEL"

FINDINGS="$WORKSPACE/.gegenlesen/findings.json"
node -e '
const fs = require("node:fs");
const path = process.argv[1];
if (!fs.existsSync(path)) {
  console.error("FAIL: findings.json was not written at " + path);
  process.exit(1);
}
const parsed = JSON.parse(fs.readFileSync(path, "utf8"));
if (!Array.isArray(parsed.findings)) {
  console.error("FAIL: findings.json has no findings array");
  process.exit(1);
}
if (parsed.findings.length < 2) {
  console.error("FAIL: expected at least 2 findings, got " + parsed.findings.length);
  process.exit(1);
}
const ruleIds = new Set(parsed.findings.map((finding) => finding.rule_id).filter(Boolean));
for (const expected of ["no-swallowed-exceptions", "no-mutable-default-args"]) {
  if (!ruleIds.has(expected)) {
    console.error("FAIL: missing expected rule_id " + expected);
    process.exit(1);
  }
}
for (const finding of parsed.findings) {
  if (!finding.snippet || typeof finding.start_line !== "number" || typeof finding.end_line !== "number") {
    console.error("FAIL: finding missing snippet or line evidence: " + JSON.stringify(finding));
    process.exit(1);
  }
  if (!finding.file_path || !finding.file_path.includes("token_cache.py")) {
    console.error("FAIL: finding missing token_cache.py evidence: " + JSON.stringify(finding));
    process.exit(1);
  }
}
console.error("OK: " + parsed.findings.length + " finding(s) at " + path);
console.log(JSON.stringify(parsed, null, 2));
' "$FINDINGS"
