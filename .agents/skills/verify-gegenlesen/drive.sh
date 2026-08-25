#!/usr/bin/env bash
set -euo pipefail

skill_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$skill_dir/../../.." && pwd)"
run="${VERIFY_RUN:-default}"
cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/gegenlesen/verify-gegenlesen"
cache="$cache_root/$run"
instance_file="$cache/instance.json"
export VERIFY_INSTANCE="$instance_file"

usage() {
  cat <<'EOF' >&2
usage: drive.sh launch [--no-key] [--with-agent]
       drive.sh doctor
       drive.sh api [METHOD] PATH [--body JSON] [--label NAME]
       drive.sh shot PATH --label NAME
       drive.sh rules-create --title T --instruction I
       drive.sh context-create --title T --body B
       drive.sh agents-save --id ID --text TEXT
       drive.sh agents-reset --id ID
       drive.sh agents-improve --id ID --instruction TEXT
       drive.sh regex-rule-create --title T --pattern P [--message M] [--id ID]
       drive.sh harvest [--label NAME]
       drive.sh cli-review [--fresh] [--keep] [--advance-base] [--probe] [--file PATH] [--content TEXT] [--label NAME]
       drive.sh wait-job [--job ID] [--label NAME]
       drive.sh job-thumb --down|--up [--job ID]
       drive.sh job-merge-intent --yes|--no [--job ID]
       drive.sh job-learn [--job ID]
       drive.sh job-should-be-rule [--job ID]
       drive.sh learning-accept [--kind KIND]
       drive.sh rule-promote --id ID
       drive.sh rule-disable --id ID
       drive.sh cleanup
EOF
  exit 2
}

instance_set() {
  python3 -c 'import json,sys
p,k,v=sys.argv[1:4]
d=json.load(open(p))
d[k]=v
json.dump(d, open(p,"w"), indent=2)
print(open(p).read())' "$instance_file" "$1" "$2"
}

fixture_repo() {
  echo "$cache/fixture-repo"
}

ensure_fixture() {
  local repo
  repo="$(fixture_repo)"
  if [[ -d "$repo/.git" ]]; then
    return 0
  fi
  mkdir -p "$repo"
  (
    cd "$repo"
    git init -q -b main
    git remote add origin git@github.com:gegenlesen/verify-fixture.git
    printf 'v1\n' >README.md
    git add README.md
    git -c user.name=gegenlesen -c user.email=gegenlesen@localhost commit -q -m v1
    git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
  )
}

tick_fixture() {
  local repo
  repo="$(fixture_repo)"
  local n=0
  if [[ -f "$repo/.verify-tick" ]]; then
    n="$(cat "$repo/.verify-tick")"
  fi
  printf '%s\n' "$((n + 1))" >"$repo/.verify-tick"
  (
    cd "$repo"
    git add .verify-tick
    git -c user.name=gegenlesen -c user.email=gegenlesen@localhost commit -q -m "tick $((n + 1))" || true
  )
}

write_fixture_file() {
  local rel="$1"
  local content="$2"
  local repo
  repo="$(fixture_repo)"
  mkdir -p "$repo/$(dirname "$rel")"
  printf '%s\n' "$content" >"$repo/$rel"
  (
    cd "$repo"
    git add "$rel"
    git -c user.name=gegenlesen -c user.email=gegenlesen@localhost commit -q -m "$rel" || true
  )
}

harvest_if_needed() {
  if [[ "$(json_get harvested 2>/dev/null || true)" == "true" ]]; then
    return 0
  fi
  cmd_harvest
}

run_gegenlesen() {
  local repo
  repo="$(fixture_repo)"
  local base
  base="$(json_get baseUrl)"
  (
    cd "$repo"
    export GEGENLESEN_URL="$base"
    export GEGENLESEN_TIMEOUT="${GEGENLESEN_TIMEOUT:-2m}"
    "$root/.build/debug/gegenlesen" "$@"
  )
}

job_id_arg() {
  local job=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job) job="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -z "$job" ]]; then
    job="$(json_get lastJobId 2>/dev/null || true)"
  fi
  if [[ -z "$job" ]]; then
    echo "no --job and no lastJobId; run cli-review first" >&2
    exit 1
  fi
  printf '%s' "$job"
}

need_instance() {
  if [[ ! -f "$instance_file" ]]; then
    echo "no instance at $instance_file; run launch first" >&2
    exit 1
  fi
}

json_get() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],"") or "")' "$instance_file" "$1"
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

port_owner() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN -F p 2>/dev/null | awk '/^p/{print substr($0,2); exit}'
}

ensure_frontend() {
  if [[ ! -f "$root/frontend/dist/index.html" ]]; then
    (cd "$root/frontend" && npm install && npm run build)
  fi
}

ensure_bins() {
  (
    cd "$root"
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    ./scripts/swift build --product GegenlesenAPI
    ./scripts/swift build --product gegenlesen
  )
}

ensure_playwright() {
  if [[ ! -d "$skill_dir/node_modules/playwright" ]]; then
    (cd "$skill_dir" && npm install)
  fi
}

write_config() {
  local dest="$1"
  local port="$2"
  local data_dir="$3"
  local with_key="$4"
  python3 - "$dest" "$port" "$data_dir" "$with_key" "$root/config/gegenlesen.example.json" <<'PY'
import json, sys
dest, port, data_dir, with_key, src = sys.argv[1:6]
cfg = json.load(open(src))
cfg["bind"] = "127.0.0.1"
cfg["port"] = int(port)
cfg["data_dir"] = data_dir
if with_key == "1":
    cfg["openrouter_api_key"] = "sk-or-verify-not-a-real-key"
json.dump(cfg, open(dest, "w"), indent=2)
print(dest)
PY
}

cmd_launch() {
  local no_key=0 with_agent=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-key) no_key=1; shift ;;
      --with-agent) with_agent=1; shift ;;
      *) usage ;;
    esac
  done

  mkdir -p "$cache"
  if [[ -f "$instance_file" ]]; then
    local old_pid
    old_pid="$(json_get pid 2>/dev/null || true)"
    if pid_alive "$old_pid"; then
      echo "already launched pid=$old_pid port=$(json_get port). cleanup first or pick a new VERIFY_RUN." >&2
      exit 1
    fi
  fi

  ensure_frontend
  ensure_bins

  local port data_dir config_path skip_agent
  port="$(free_port)"
  data_dir="$cache/data"
  rm -rf "$data_dir"
  mkdir -p "$data_dir" "$cache/config"
  config_path="$cache/config/gegenlesen.json"
  if [[ "$no_key" -eq 1 ]]; then
    write_config "$config_path" "$port" "$data_dir" 0
  else
    write_config "$config_path" "$port" "$data_dir" 1
  fi
  if [[ "$with_agent" -eq 1 ]]; then
    skip_agent=0
  else
    skip_agent=1
  fi

  local log="$cache/api.log"
  : >"$log"
  (
    cd "$root"
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    export GEGENLESEN_ROOT="$root"
    export GEGENLESEN_CONFIG="$config_path"
    export GEGENLESEN_DATA_DIR="$data_dir"
    export GEGENLESEN_BIND="127.0.0.1"
    export GEGENLESEN_PORT="$port"
    if [[ "$skip_agent" -eq 1 ]]; then
      export GEGENLESEN_SKIP_AGENT=1
    else
      unset GEGENLESEN_SKIP_AGENT || true
    fi
    if [[ "$no_key" -eq 1 ]]; then
      export OPENROUTER_API_KEY=""
    fi
    exec "$root/.build/debug/GegenlesenAPI" serve \
      --bind 127.0.0.1 \
      --port "$port" \
      --data-dir "$data_dir"
  ) >>"$log" 2>&1 &
  local pid=$!

  python3 - "$instance_file" "$pid" "$port" "$data_dir" "$config_path" "$log" "$skip_agent" "$cache" "$root" <<'PY'
import json, sys
path, pid, port, data_dir, config, log, skip, cache, root = sys.argv[1:]
json.dump({
    "pid": int(pid),
    "port": int(port),
    "baseUrl": f"http://127.0.0.1:{port}",
    "dataDir": data_dir,
    "configPath": config,
    "logPath": log,
    "skipAgent": skip == "1",
    "evidenceDir": cache,
    "root": root,
}, open(path, "w"), indent=2)
print(open(path).read())
PY

  local i=0
  while (( i < 60 )); do
    if ! pid_alive "$pid"; then
      echo "API exited during launch. log: $log" >&2
      tail -n 80 "$log" >&2 || true
      exit 1
    fi
    if curl -sf "http://127.0.0.1:$port/api/health" >/dev/null; then
      curl -s "http://127.0.0.1:$port/api/health"
      echo
      echo "ready $pid http://127.0.0.1:$port"
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  echo "health never answered. log: $log" >&2
  tail -n 80 "$log" >&2 || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  exit 1
}

cmd_doctor() {
  need_instance
  python3 - "$instance_file" <<'PY'
import json, os, socket, subprocess, sys, urllib.request

inst = json.load(open(sys.argv[1]))
pid = inst["pid"]
port = inst["port"]
checks = {}

def alive(p):
    try:
        os.kill(p, 0)
        return True
    except OSError:
        return False

checks["processAlive"] = alive(pid)

owner = None
try:
    out = subprocess.check_output(
        ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-F", "p"],
        text=True,
        stderr=subprocess.DEVNULL,
    )
    for line in out.splitlines():
        if line.startswith("p"):
            owner = int(line[1:])
            break
except subprocess.CalledProcessError:
    owner = None
checks["portOwner"] = owner
checks["portOwnedByUs"] = owner == pid

health = None
settings = None
spa = None
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=3) as r:
        health = json.load(r)
        checks["healthStatus"] = r.status
except Exception as e:
    checks["healthStatus"] = None
    checks["healthError"] = str(e)
checks["healthOk"] = bool(health and health.get("ok") is True)
checks["version"] = (health or {}).get("version")

try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/settings", timeout=3) as r:
        settings = json.load(r)
        checks["settingsStatus"] = r.status
except Exception as e:
    checks["settingsStatus"] = None
    checks["settingsError"] = str(e)
checks["bindLoopback"] = (settings or {}).get("bind") == "127.0.0.1"
checks["settingsPort"] = (settings or {}).get("port") == port
checks["openrouterConfigured"] = (settings or {}).get("openrouter_configured")

try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=3) as r:
        body = r.read().decode("utf-8", "replace")
        spa = r.status
        checks["spaStatus"] = spa
        checks["spaIsLedger"] = "gegenlesen" in body.lower()
except Exception as e:
    checks["spaStatus"] = None
    checks["spaError"] = str(e)

sqlite = os.path.join(inst["dataDir"], "gegenlesen.sqlite")
if not os.path.exists(sqlite):
    sqlite = os.path.join(inst["dataDir"], "gegenlesen.db")
checks["sqliteExists"] = os.path.exists(os.path.join(inst["dataDir"], "gegenlesen.sqlite")) or os.path.exists(
    os.path.join(inst["dataDir"], "gegenlesen.db")
)
checks["dataDirIsOurs"] = inst["dataDir"].startswith(inst["evidenceDir"])
checks["skipAgent"] = inst.get("skipAgent")

ok = all(
    [
        checks.get("processAlive"),
        checks.get("portOwnedByUs"),
        checks.get("healthOk"),
        checks.get("bindLoopback"),
        checks.get("settingsPort"),
        checks.get("spaIsLedger"),
        checks.get("dataDirIsOurs"),
    ]
)
result = {"ok": ok, "instance": inst, "checks": checks}
print(json.dumps(result, indent=2))
sys.exit(0 if ok else 1)
PY
}

cmd_api() {
  need_instance
  local method="GET" path="" body="" label="api"
  if [[ $# -eq 0 ]]; then usage; fi
  if [[ "$1" == GET || "$1" == POST || "$1" == PUT || "$1" == PATCH || "$1" == DELETE ]]; then
    method="$1"
    shift
  fi
  path="${1:-}"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --body) body="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$path" ]]; then usage; fi
  local base
  base="$(json_get baseUrl)"
  local url="$base$path"
  local out="$cache/$label.json"
  python3 - "$method" "$url" "$body" "$out" <<'PY'
import json, sys, urllib.request
method, url, body, out = sys.argv[1:5]
data = None if not body else body.encode()
headers = {"Accept": "application/json"}
if data is not None:
    headers["Content-Type"] = "application/json"
req = urllib.request.Request(url, data=data, method=method, headers=headers)
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        status = r.status
except urllib.error.HTTPError as e:
    raw = e.read()
    status = e.code
text = raw.decode("utf-8", "replace")
try:
    parsed = json.loads(text) if text else None
except json.JSONDecodeError:
    parsed = text
result = {"method": method, "url": url, "status": status, "body": parsed}
open(out, "w").write(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
sys.exit(0 if 200 <= status < 300 else 1)
PY
}

cmd_shot() {
  need_instance
  ensure_playwright
  local path="/" label="shot"
  path="${1:-/}"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  (cd "$skill_dir" && node browser.mjs shot "$path" "$label")
}

cmd_rules_create() {
  need_instance
  ensure_playwright
  local title="" instruction=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --instruction) instruction="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$title" || -z "$instruction" ]]; then usage; fi
  (cd "$skill_dir" && node browser.mjs rules-create "$title" "$instruction")
}

cmd_context_create() {
  need_instance
  ensure_playwright
  local title="" body=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$title" || -z "$body" ]]; then usage; fi
  (cd "$skill_dir" && node browser.mjs context-create "$title" "$body")
}

cmd_agents_save() {
  need_instance
  ensure_playwright
  local id="" text=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      --text) text="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$id" || -z "$text" ]]; then usage; fi
  (cd "$skill_dir" && node browser.mjs agents-save "$id" "$text")
}

cmd_agents_reset() {
  need_instance
  ensure_playwright
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$id" ]]; then usage; fi
  (cd "$skill_dir" && node browser.mjs agents-reset "$id")
}

cmd_agents_improve() {
  need_instance
  ensure_playwright
  local id="" instruction=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      --instruction) instruction="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$id" || -z "$instruction" ]]; then usage; fi
  (cd "$skill_dir" && node browser.mjs agents-improve "$id" "$instruction")
}

cmd_harvest() {
  need_instance
  ensure_fixture
  local label="harvest"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  local out="$cache/${label}.txt"
  set +e
  run_gegenlesen harvest --timeout 2m >"$out" 2>&1
  local code=$?
  set -e
  cat "$out"
  if [[ "$code" -ne 0 ]]; then
    echo "gegenlesen harvest exited $code" >&2
    exit "$code"
  fi
  local job_id
  job_id="$(head -n 1 "$out")"
  cmd_api GET "/api/jobs/$job_id" --label "$label-job"
  instance_set harvested true >/dev/null
  instance_set lastHarvestId "$job_id" >/dev/null
}

cmd_regex_rule_create() {
  need_instance
  local title="" pattern="" message="probe" id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --pattern) pattern="$2"; shift 2 ;;
      --message) message="$2"; shift 2 ;;
      --id) id="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$title" || -z "$pattern" ]]; then usage; fi
  local body
  body="$(python3 -c 'import json,sys
title, pattern, message, rid = sys.argv[1:5]
payload = {
  "title": title,
  "severity": "warning",
  "kind": "deterministic",
  "enabled": True,
  "languages": ["swift"],
  "path_globs": ["**/*.swift"],
  "payload": {"checker": "regex", "pattern": pattern, "message": message},
}
if rid:
  payload["id"] = rid
print(json.dumps(payload))
' "$title" "$pattern" "$message" "$id")"
  cmd_api POST /api/rules --body "$body" --label regex-rule
}

cmd_cli_review() {
  need_instance
  local keep=0 probe=0 advance=0 label="cli-review" file="" content=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fresh) keep=0; shift ;;
      --keep) keep=1; shift ;;
      --advance-base) advance=1; shift ;;
      --probe) probe=1; shift ;;
      --file) file="$2"; shift 2 ;;
      --content) content="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ "$keep" -eq 0 ]]; then
    rm -rf "$(fixture_repo)"
    instance_set harvested false >/dev/null
  fi
  ensure_fixture
  harvest_if_needed
  if [[ "$advance" -eq 1 ]]; then
    (
      cd "$(fixture_repo)"
      git update-ref refs/remotes/origin/main "$(git rev-parse HEAD)"
    )
  fi
  if [[ "$probe" -eq 1 ]]; then
    write_fixture_file "Sources/Probe.swift" "eval(__gegenlesen_probe__)"
  fi
  if [[ -n "$file" ]]; then
    if [[ -z "$content" ]]; then
      echo "--file requires --content" >&2
      exit 2
    fi
    write_fixture_file "$file" "$content"
  fi
  if [[ "$keep" -eq 1 ]]; then
    tick_fixture
  elif [[ "$probe" -eq 0 && -z "$file" ]]; then
    local repo
    repo="$(fixture_repo)"
    printf 'v2\n' >"$repo/README.md"
    (
      cd "$repo"
      git add README.md
      git -c user.name=gegenlesen -c user.email=gegenlesen@localhost commit -q -m v2
    )
  fi
  local out="$cache/${label}.txt"
  set +e
  run_gegenlesen review >"$out" 2>&1
  local code=$?
  set -e
  cat "$out"
  if [[ "$code" -ne 0 ]]; then
    echo "gegenlesen review exited $code" >&2
    exit "$code"
  fi
  local job_id
  job_id="$(head -n 1 "$out")"
  instance_set lastJobId "$job_id" >/dev/null
  cmd_api GET "/api/jobs/$job_id" --label "${label}-job"
}

cmd_wait_job() {
  need_instance
  local job="" label="wait-job"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job) job="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$job" ]]; then
    job="$(job_id_arg --job "")"
  fi
  local i=0
  local status=""
  while (( i < 120 )); do
    cmd_api GET "/api/jobs/$job" --label "$label" >/dev/null
    status="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
body=d.get("body") or {}
print(body.get("status") or "")
' "$cache/${label}.json")"
    case "$status" in
      succeeded|failed|cancelled)
        python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(json.dumps(d, indent=2))
' "$cache/${label}.json"
        if [[ "$status" != "succeeded" ]]; then
          echo "job $job ended $status" >&2
          exit 1
        fi
        return 0
        ;;
    esac
    sleep 1
    i=$((i + 1))
  done
  echo "job $job still $status after 120s" >&2
  exit 1
}

cmd_job_thumb() {
  need_instance
  ensure_playwright
  local dir="" job=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --down) dir="down"; shift ;;
      --up) dir="up"; shift ;;
      --job) job="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$dir" ]]; then usage; fi
  if [[ -z "$job" ]]; then job="$(job_id_arg)"; fi
  (cd "$skill_dir" && node browser.mjs job-thumb "$job" "$dir")
}

cmd_job_merge_intent() {
  need_instance
  ensure_playwright
  local answer="" job=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) answer="yes"; shift ;;
      --no) answer="no"; shift ;;
      --job) job="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$answer" ]]; then usage; fi
  if [[ -z "$job" ]]; then job="$(job_id_arg)"; fi
  (cd "$skill_dir" && node browser.mjs job-merge-intent "$job" "$answer")
}

cmd_job_learn() {
  need_instance
  ensure_playwright
  local job=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job) job="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$job" ]]; then job="$(job_id_arg)"; fi
  local result
  result="$(cd "$skill_dir" && node browser.mjs job-learn "$job")"
  echo "$result"
  local learn_id
  learn_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("learnJobId") or "")' <<<"$result")"
  if [[ -z "$learn_id" ]]; then
    echo "learn did not return a job id" >&2
    exit 1
  fi
  instance_set lastLearnId "$learn_id" >/dev/null
  cmd_wait_job --job "$learn_id" --label learn-job
}

cmd_job_should_be_rule() {
  need_instance
  ensure_playwright
  local job=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --job) job="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$job" ]]; then job="$(job_id_arg)"; fi
  (cd "$skill_dir" && node browser.mjs job-should-be-rule "$job")
  cmd_api GET "/api/jobs/$job/feedback" --label should-be-rule-feedback
}

cmd_learning_accept() {
  need_instance
  ensure_playwright
  local kind=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) kind="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  (cd "$skill_dir" && node browser.mjs learning-accept "$kind")
}

cmd_rule_promote() {
  need_instance
  ensure_playwright
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$id" ]]; then usage; fi
  (cd "$skill_dir" && node browser.mjs rule-promote "$id")
  cmd_api GET "/api/rules/$id" --label rule-promoted
}

cmd_rule_disable() {
  need_instance
  ensure_playwright
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ -z "$id" ]]; then usage; fi
  (cd "$skill_dir" && node browser.mjs rule-disable "$id")
}

cmd_cleanup() {
  if [[ ! -f "$instance_file" ]]; then
    echo "nothing to clean ($instance_file missing)"
    return 0
  fi
  local pid port
  pid="$(json_get pid)"
  port="$(json_get port)"
  if pid_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    local i=0
    while pid_alive "$pid" && (( i < 20 )); do
      sleep 0.2
      i=$((i + 1))
    done
    if pid_alive "$pid"; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$cache/data" "$cache/config" "$cache/fixture-repo"
  echo "stopped pid=$pid port=$port"
  echo "evidence kept in $cache"
}

[[ $# -lt 1 ]] && usage
cmd="$1"
shift
case "$cmd" in
  launch) cmd_launch "$@" ;;
  doctor) cmd_doctor "$@" ;;
  api) cmd_api "$@" ;;
  shot) cmd_shot "$@" ;;
  rules-create) cmd_rules_create "$@" ;;
  context-create) cmd_context_create "$@" ;;
  agents-save) cmd_agents_save "$@" ;;
  agents-reset) cmd_agents_reset "$@" ;;
  agents-improve) cmd_agents_improve "$@" ;;
  regex-rule-create) cmd_regex_rule_create "$@" ;;
  harvest) cmd_harvest "$@" ;;
  cli-review) cmd_cli_review "$@" ;;
  wait-job) cmd_wait_job "$@" ;;
  job-thumb) cmd_job_thumb "$@" ;;
  job-merge-intent) cmd_job_merge_intent "$@" ;;
  job-learn) cmd_job_learn "$@" ;;
  job-should-be-rule) cmd_job_should_be_rule "$@" ;;
  learning-accept) cmd_learning_accept "$@" ;;
  rule-promote) cmd_rule_promote "$@" ;;
  rule-disable) cmd_rule_disable "$@" ;;
  cleanup) cmd_cleanup "$@" ;;
  *) usage ;;
esac
