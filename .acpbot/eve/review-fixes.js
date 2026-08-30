export const meta = {
  name: 'review-fixes',
  description: 'Apply autoreview findings to PR #46 (issue-35) and PR #47 (issue-33)',
  phases: [
    { title: 'Fix' },
    { title: 'Close' },
  ],
}

const repo = (args && args.repo) || 'pmdroid/gegenlesen'

phase('Fix')
const results = await parallel([
  () => agent(
    `You are fixing review findings on a PR branch in ${repo}.\n` +
    `Setup: you work in a git worktree. Run: git fetch origin && git checkout issue-35 && git rebase origin/main (origin/main just gained an AgentEngine seam refactor — resolve conflicts if any; the seam introduced AgentEngine/AgentEngineRegistry/AgentSandbox types).\n` +
    `PR #46 implements per-slot {engine, modelID} config. A cursor-agent/Composer review found these findings. Fix the P2s and the quick P3s:\n` +
    `P2-1 SettingsRoute.swift:34-54: settings PUT accepts blank-check only; add an allowlist of known engine IDs (opencode, claude, codex, grok, cursor-agent) and return 422 for unknown engines, matching how other settings fields are guarded.\n` +
    `P2-2 Config.swift:32-35,254: decodeIfPresent treats "" as present so a hand-edited config with engine_a="" bypasses the opencode default and disagrees with Store+Jobs coalescing. Normalize on decode with the same firstNonEmpty pattern used in Store+Jobs, defaulting to opencode.\n` +
    `P2-3 OpenCodeInvocation.swift:94,119,329: the job snapshots reviewerAEngine/reviewerBEngine/judgeEngine but runtime still always invokes opencode. Add a TODO(#38) comment at each invocation site noting dispatch-by-engine lands later.\n` +
    `P3-1 Config.swift:30-36: add explicit encode(to:) on ModelSlots writing all four keys, mirroring GegenlesenConfig.encode in the same file.\n` +
    `P3-2 docs/contracts/GegenlesenTypes.swift:484-496: contract ModelSlots should use the decodeIfPresent ?? opencode pattern too (or document the default).\n` +
    `P3-3 Add snapshot assertions for the harvest, corpus, and learn-enqueue paths (they copy engines into Job rows like JobsRoute does; JobsRouteTests.swift:364-390 shows the pattern).\n` +
    `P3-4 ConfigEngineTests: add a case that loads a legacy gegenlesen.json without engine keys, PUTs an unrelated setting, and asserts the saved file contains engine_a opencode.\n` +
    `Skip the optional v3-to-v4 fixture-DB upgrade test.\n` +
    `This repo uses NO code comments except TODOs you were told to add. Follow existing conventions.\n` +
    `Verify: swift build && swift test (all targets); frontend under frontend/ untouched, so no npm needed unless you touch it.\n` +
    `Commit with a concise message, push to origin issue-35 (updates PR #46). Do NOT merge.\n` +
    `Final message: print JSON only.`,
    {
      label: 'fix-issue-35',
      phase: 'Fix',
      role: 'implementer',
      agent: 'cursor-agent',
      timeout_sec: 3000,
      schema: {
        type: 'object',
        required: ['status', 'summary'],
        properties: {
          status: { type: 'string', enum: ['done', 'blocked', 'partial'] },
          summary: { type: 'string' },
          prUrl: { type: 'string' },
        },
      },
    },
  ),
  () => agent(
    `You are fixing review findings on a PR branch in ${repo}.\n` +
    `Setup: you work in a git worktree. Run: git fetch origin && git checkout issue-33 && git rebase origin/main.\n` +
    `PR #47 is the ACP spike (scripts/spike-acp.sh, scripts/spike-acp-client.mjs, docs/spike-acp-one-shot.md). A cursor-agent/Composer review returned REQUEST-CHANGES with these findings. Fix the P1s and the cheap P2/P3s:\n` +
    `P1-1 scripts/spike-acp.sh:197-201: the post-run gate accepts 0 findings. Assert findings.length >= 2, assert the expected rule_ids no-swallowed-exceptions and no-mutable-default-args are present, and check each finding has snippet and line evidence for the planted defects in src/token_cache.py. Exit non-zero otherwise.\n` +
    `P1-2 docs/spike-acp-one-shot.md:17-18: the canonical reproduce command must use OPENCODE_API_KEY (the only key proven end-to-end per the doc itself); demote OPENROUTER_API_KEY to an auth-wiring-only note.\n` +
    `P1-3 No committed artifacts: search for leftover spike outputs (transcript.jsonl, findings.json) in git worktrees under this repo and in /var/folders temp dirs; if real artifacts exist, commit a REDACTED fixture pair under Tests/Fixtures/ with a capture note. If none exist, do NOT fabricate them: adjust the doc claims to state verification requires a live run and remove the unverifiable '2/2 verified' framing.\n` +
    `P1-4 Add -e OPENCODE_EXPERIMENTAL_LSP_TOOL=true to the spike docker run (script + doc snippet) to match production OpenCodeInvocation.swift:501, and correct the 'byte-for-byte the production set' claim accordingly.\n` +
    `P2-1 spike-acp-client.mjs:77-101: log loudly whenever a session/request_permission arrives; the doc says production needs zero round-trips, so any occurrence should be surfaced prominently.\n` +
    `P2-2 spike-acp-client.mjs transcript writing: add basic redaction of sk- prefixed keys, api_key values, and bearer tokens before appendFileSync, and note 'delete transcript after run' in the doc.\n` +
    `P2-3 spike-acp.sh: add a guard that the image gegenlesen/opencode-runner:0.1.0 exists (docker image inspect) with a clear 'run scripts/build-runner.sh' message before the long timeout.\n` +
    `P3-1 Link docs/spike-acp-one-shot.md from docs/technical-plan.md (one line).\n` +
    `P3-2 Document the Linux chown prerequisite (production runs DockerRunner.chownWorkspace; spike skips it; Linux with uid 1000 may need chown -R 1000:1000 on the temp workspace).\n` +
    `Keep scripts in existing style (set -euo pipefail). No code comments.\n` +
    `You cannot run the spike end-to-end (needs live API keys and ~8 min); validate shell syntax with bash -n and node --check, and keep changes surgical.\n` +
    `Commit with a concise message, push to origin issue-33 (updates PR #47). Do NOT merge.\n` +
    `Final message: print JSON only.`,
    {
      label: 'fix-issue-33',
      phase: 'Fix',
      role: 'implementer',
      agent: 'cursor-agent',
      timeout_sec: 3000,
      schema: {
        type: 'object',
        required: ['status', 'summary'],
        properties: {
          status: { type: 'string', enum: ['done', 'blocked', 'partial'] },
          summary: { type: 'string' },
          prUrl: { type: 'string' },
        },
      },
    },
  ),
])

phase('Close')
const ok = (results || []).filter(Boolean)
const blocked = ok.filter((r) => r.status !== 'done')
log(`done=${ok.filter((r) => r.status === 'done').length} blocked=${blocked.length}`)
if (blocked.length) {
  const decision = await host.ask({
    question: `Fix leaf blocked/partial: ${blocked.map((r) => r.summary).join(' | ')}. What next?`,
    options: [
      { id: 'retry', label: 'Retry' },
      { id: 'accept', label: 'Accept and stop' },
    ],
  })
  return { results: ok, blocked: blocked.length, operatorDecision: decision }
}
return { results: ok, blocked: 0 }
