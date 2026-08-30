# Spike: one-shot ACP run inside the hardened container

Issue #33. Exercised 2026-08-29 on macOS (Docker 29.4.0), image built from
`docker/opencode-runner/` (opencode 1.1.25, anomalyco build; bundled bun 1.3.5).

## Result

opencode's native ACP server (`opencode acp`) can complete one review prompt
end-to-end inside the existing hardened sandbox and write a valid
`/workspace/.gegenlesen/findings.json` itself. `claude-code-acp` was not
exercised; one working adapter satisfies the spike and opencode is what the
runner image already ships.

Verification requires a live run with a valid provider API key (~8 min).
The post-run gate in `scripts/spike-acp.sh` asserts at least two findings with
the planted rule IDs, snippets, and line evidence for `src/token_cache.py`.

Reproduce:

```bash
OPENCODE_API_KEY=... ./scripts/spike-acp.sh
```

`OPENROUTER_API_KEY` (and other provider keys) follow the same env pass-through
wiring as production; only `OPENCODE_API_KEY` was proven end-to-end for a full
successful review during the spike.

`scripts/spike-acp.sh` stages a demo workspace (planted Python defects, rules,
diff, prompt) and starts the container; `scripts/spike-acp-client.mjs` is a
dependency-free Node ACP client that talks newline-delimited JSON-RPC to the
agent through `docker run -i` stdio. Delete `transcript.jsonl` after the run;
it may contain redacted-but-sensitive protocol frames.

## Working invocation

The container flags match the production set from
`OpenCodeInvocation.isolatedDockerRequest`, plus `-i` for ACP stdio and
`OPENCODE_EXPERIMENTAL_LSP_TOOL=true` (same as production):

```bash
docker run --rm -i --name gegenlesen-acp-spike-$$ \
  --network gegenlesen-egress \
  --workdir /workspace \
  --user 1000:1000 \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,uid=1000,gid=1000,size=512m \
  --tmpfs /home/gegenlesen/.local:rw,nosuid,nodev,uid=1000,gid=1000,size=256m \
  --tmpfs /home/gegenlesen/.cache:rw,nosuid,nodev,uid=1000,gid=1000,size=64m \
  --tmpfs /home/gegenlesen/.config/opencode:rw,nosuid,nodev,uid=1000,gid=1000,size=64m \
  --tmpfs /home/gegenlesen/.config/opencode-state:rw,nosuid,nodev,uid=1000,gid=1000,size=64m \
  --mount type=bind,src=$WORKSPACE,dst=/workspace \
  --mount type=bind,src=$SEED,dst=/opt/gegenlesen/opencode,readonly \
  --cpus 2 --memory 4g --pids-limit 256 \
  --cap-drop ALL --security-opt no-new-privileges \
  --ulimit nproc=256:256 --ulimit nofile=1024:1024 \
  -e OPENCODE_API_KEY \
  -e HOME=/home/gegenlesen \
  -e XDG_CACHE_HOME=/home/gegenlesen/.cache \
  -e OPENCODE_DISABLE_AUTOUPDATE=true \
  -e OPENCODE_AUTO_SHARE=false \
  -e OPENCODE_DISABLE_DEFAULT_PLUGINS=true \
  -e OPENCODE_DISABLE_CLAUDE_CODE=true \
  -e OPENCODE_EXPERIMENTAL_LSP_TOOL=true \
  -e OPENCODE_CONFIG=/home/gegenlesen/.config/opencode/opencode.json \
  -e OPENCODE_CONFIG_CONTENT="$POLICY_JSON" \
  -e OPENCODE_PERMISSION="$PERMISSION_JSON" \
  "$IMAGE" \
  /bin/sh -c 'cp -a /opt/gegenlesen/opencode/. /home/gegenlesen/.config/opencode/ && exec "$@"' opencode \
  opencode acp --print-logs --log-level WARN
```

The only deltas versus the `opencode run` path: `-i` (the ACP client owns the
container's stdin/stdout for JSON-RPC) and `opencode acp` instead of
`opencode run`.

## Linux workspace ownership

Production runs `DockerRunner.chownWorkspace` before agent containers start.
The spike skips that step. On Linux hosts where the bind-mounted workspace is
owned by the invoking user (not uid 1000), run
`chown -R 1000:1000 "$WORKSPACE"` on the temp workspace before `docker run`.

## ACP handshake observed

- `initialize` with `protocolVersion: 1` → agent replies protocolVersion 1,
  `agentInfo {name: "OpenCode", version: "1.1.25"}`, capabilities
  `loadSession: true`, `promptCapabilities {embeddedContext: true, image: true}`.
- `session/new {cwd: "/workspace", mcpServers: []}` → `sessionId` plus the
  model list; the model comes from config, not from a session parameter.
- `session/prompt` with a `text` block plus an embedded `resource` block
  carrying `prompt.md` → streams `session/update` notifications
  (`agent_message_chunk`, `tool_call`, `tool_call_update`) and resolves with
  `{stopReason: "end_turn"}`.

## Auth via env API keys

- Provider keys pass as `-e KEY` name-only pass-through (value stays in the
  docker CLI process env, never on argv), exactly like production.
- `authenticate` was never required: the advertised `opencode-login` auth
  method can be ignored when a provider key is present in the env.
- Verified end-to-end with `OPENCODE_API_KEY` (opencode zen,
  `opencode/nemotron-3.5-lightning-free`). The `OPENROUTER_API_KEY` path was
  verified to reach the provider (the only available key is expired; OpenRouter
  answered "API key expired", proving env auth wiring without interactive
  OAuth).

## Required writable paths

The production tmpfs set is sufficient; no EROFS errors appeared anywhere:

| Path | Why ACP mode needs it |
| --- | --- |
| `/tmp` | scratch, bun tmp files |
| `/home/gegenlesen/.local` | `~/.local/share/opencode`: session storage + migrations |
| `/home/gegenlesen/.cache` | models.dev catalog cache |
| `/home/gegenlesen/.config/opencode` | seed copy target; bun installs `@opencode-ai/plugin` here at bootstrap |
| `/home/gegenlesen/.config/opencode-state` | opencode state dir |

## Permission auto-approval

With the production permission policy (config `permission` block seeded via
`opencode.json` + `OPENCODE_PERMISSION`), the agent auto-approved everything
server-side: zero `session/request_permission` round-trips across 12 tool calls
(read x6, execute x2, edit x1, other x3). The spike client still implements the
handler (answers `allow_always`/`allow_once`) as a fallback for stricter
policies. Any `session/request_permission` frame is logged loudly because
production needs zero round-trips.

## Output files and transcript capture

- The agent wrote `findings.json` with its own `write` tool; the client
  declares `fs: {readTextFile: false, writeTextFile: false}` so no host-side
  file proxying is involved.
- Full transcript (every JSON-RPC frame both directions + agent stderr) lands
  in `transcript.jsonl`; `agent_message_chunk` updates give live progress that
  `opencode run --format json` never exposed mid-run. Delete the transcript
  after the run.

## Nested-sandbox gotchas / decision notes

- `stopReason: "end_turn"` is returned even when the provider call fails
  (observed with the expired OpenRouter key). Exit code and stop reason are not
  success signals; keep treating a missing/invalid `findings.json` as the
  failure condition (`reviewer_no_findings_file`).
- At bootstrap `opencode acp` runs bun to install `@opencode-ai/plugin` into
  `~/.config/opencode` (~800ms, hits the npm registry through
  `gegenlesen-egress`). A registry outage would break startup; pre-baking the
  package into the image would remove that dependency.
- Log volume: `--log-level INFO` produced ~360 MB of stderr for one review
  (protocol traffic was ~5 MB); the same run at WARN captured ~1 MB total. Use
  WARN; `DockerRunner`'s 20 MB capture cap would otherwise truncate and kill
  the container mid-run.
- `DockerRunner` currently wires `standardInput: FileHandle.nullDevice` and
  DockerRequest has no stdin support. Integrating ACP for real needs a
  stdin-attached run mode (or `docker exec -i` into a long-lived container).
- Closing the client's stdin pipe ends the agent process; the client must hold
  stdin open for the whole session and close it to shut down cleanly.
- Session title generation fires an extra small-model request
  (`anthropic/claude-haiku-4.5` via the configured provider); harmless when it
  fails but it is billable when it succeeds.
- One session ran ~7.5 min on the free zen model with 2 CPUs / 4 GB / pids 256;
  no resource-limit hits (bun + LSP servers stayed well under the pids cap).
