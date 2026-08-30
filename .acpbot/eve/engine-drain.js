export const meta = {
  name: 'engine-drain',
  description: 'Drain the multi-engine GitHub issues (#33-#44) in dependency waves',
  phases: [
    { title: 'Discover' },
    { title: 'Work' },
    { title: 'Close' },
  ],
}

const repo = (args && args.repo) || 'pmdroid/gegenlesen'
const maxPerWave = (args && args.maxPerWave) || 3

phase('Discover')
const found = await agent(
  `List the state of GitHub issues 33 through 44 in ${repo}. For each number run: gh issue view <n> --repo ${repo} --json number,title,state,body. Parse each body's "Blocked by" section: entries like "- #35" are blockers; "None - can start immediately" means no blockers. Return JSON only.`,
  {
    label: 'discover',
    agent: 'cursor-agent',
    timeout_sec: 600,
    schema: {
      type: 'object',
      required: ['issues'],
      properties: {
        issues: {
          type: 'array',
          items: {
            type: 'object',
            required: ['number', 'title', 'state', 'blockedBy'],
            properties: {
              number: { type: 'integer' },
              title: { type: 'string' },
              state: { type: 'string' },
              blockedBy: { type: 'array', items: { type: 'integer' } },
            },
          },
        },
      },
    },
  },
)

let issues = (found && found.issues) ? found.issues : []
issues = issues.filter((i) => String(i.state).toUpperCase() === 'OPEN')
if (!issues.length) {
  log('no open issues in range 33-44')
  return { done: 0, blocked: 0 }
}

const openNumbers = new Set(issues.map((i) => i.number))
const ready = issues.filter((i) => !(i.blockedBy || []).some((b) => openNumbers.has(b)))
const wave = ready.slice(0, maxPerWave)
log(`open=${issues.length} ready=${ready.length} wave=${wave.map((i) => '#' + i.number).join(', ') || 'none'}`)

if (!wave.length) {
  const decision = await host.ask({
    question: `All ${issues.length} open issues are blocked by other open issues. Stop here?`,
    options: [
      { id: 'stop', label: 'Stop and wait for merges' },
    ],
  })
  return { blocked: issues.length, operatorDecision: decision }
}

if (!budget.ok()) {
  log('budget exhausted before Work phase')
  return { blocked: wave.length }
}

phase('Work')
const results = await parallel(wave.map((issue) => () =>
  agent(
    `You are implementing exactly one GitHub issue in ${repo}: #${issue.number} — ${issue.title}.\n` +
    `Steps:\n` +
    `1. Read the full issue: gh issue view ${issue.number} --repo ${repo}\n` +
    `2. You work in a git worktree. Create a branch named issue-${issue.number}.\n` +
    `3. Implement the issue end-to-end per its acceptance criteria. This is a Swift/Vapor backend (swift build / swift test) with a React frontend under frontend/ (npm ci && npm run build; run frontend tests if present). Follow existing code conventions; do not add comments.\n` +
    `4. Verify: run the relevant builds and tests; fix failures before proceeding.\n` +
    `5. Commit with a concise message, push the branch, and open a PR against main with gh pr create. PR body: summarize the change and include "Closes #${issue.number}" only if every acceptance criterion is met.\n` +
    `6. Comment on the issue with the PR link: gh issue comment ${issue.number} --repo ${repo} --body "...".\n` +
    `Do NOT close the issue and do NOT merge the PR.\n` +
    `If you cannot complete it (missing credentials, docker unavailable, etc.), report status "blocked" with the exact reason in summary.\n` +
    `Your final message must print JSON only, matching the schema.`,
    {
      label: `issue-${issue.number}`,
      phase: 'Work',
      role: 'implementer',
      agent: 'cursor-agent',
      timeout_sec: 3600,
      schema: {
        type: 'object',
        required: ['status', 'summary', 'issueNumber'],
        properties: {
          status: { type: 'string', enum: ['done', 'blocked', 'partial'] },
          summary: { type: 'string' },
          prUrl: { type: 'string' },
          issueNumber: { type: 'integer' },
        },
      },
    },
  ),
))

phase('Close')
const ok = (results || []).filter(Boolean)
const done = ok.filter((r) => r.status === 'done')
const blocked = ok.filter((r) => r.status !== 'done')
log(`done=${done.length} blocked=${blocked.length}`)
if (blocked.length) {
  const decision = await host.ask({
    question: `${blocked.length} issue(s) blocked or partial: ${blocked.map((r) => '#' + (r.issueNumber || '?')).join(', ')}. What next?`,
    options: [
      { id: 'retry', label: 'Re-run blocked issues' },
      { id: 'accept', label: 'Accept and stop' },
    ],
  })
  return { results: ok, blocked: blocked.length, operatorDecision: decision }
}
return { results: ok, blocked: 0 }
