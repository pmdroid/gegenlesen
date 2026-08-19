# Gegenlesen technical plan

Implementation contract. Other agents and PRs **must** match these types, names, JSON keys, and HTTP shapes. Narrative and rationale live in [`gegenlesen-pr-review-service.md`](gegenlesen-pr-review-service.md). If this file and the design disagree on a type or wire field, **this file wins** and the design should be updated.

| Artifact | Role |
| --- | --- |
| [`contracts/GegenlesenTypes.swift`](contracts/GegenlesenTypes.swift) | Swift enums / structs / actors (copy into `Sources/` in PR 2) |
| [`contracts/api.ts`](contracts/api.ts) | TypeScript wire types (copy into `frontend/src/` in PR 1) |
| [`../schemas/openapi.yaml`](../schemas/openapi.yaml) | HTTP surface |
| [`../schemas/findings.agent.json`](../schemas/findings.agent.json) | Agent output file |
| [`../schemas/judge.json`](../schemas/judge.json) | Judge output file |
| [`../schemas/judge-input.json`](../schemas/judge-input.json) | Host → judge file |

Cross-check: `openapi.yaml` + JSON Schema files are the machine source of truth for JSON. Swift/TS files must decode them 1:1 (`snake_case` on the wire).

### Cross-check log (2026-08-17)

First systematic pass: design doc vs this plan vs Swift vs TypeScript vs OpenAPI vs JSON Schema. **Not** a runtime or OpenAPI-validator run — those tools are not in the repo yet.

**Aligned**

- Job status / scope / severity / lifecycle / phase / provenance / checker enums.
- `POST /api/jobs` parts, 202 body, 400/413/415/422/507 rules, preferred pack is 202 without SHAs.
- Finding wire fields in the design example (`id`, `job_id`, `rule_id`, `phase`, `severity`, `title`, `message`, `file_path`, lines, `snippet`, judge_*, `lifecycle`, `evidence_ok`).
- Agent / judge / judge-input file shapes and host-assigned `fnd_` ids.
- State machine transitions (including skip-agent and empty-reviewer → succeeded).
- Settings limits keys and default numbers.
- Host requirements, Docker names, quarantine rename.

**SQL column ≠ HTTP key (intentional; implementers must map)**

| SQL | HTTP / seed YAML |
| --- | --- |
| `jobs.reviewer_slot` | `reviewer_model_slot` |
| `jobs.timings_json` | not on `JobDetail` (internal) |
| `jobs.updated_at` | not on `JobDetail` |
| `rules.body_md` | `body` |
| `rules.languages_json` | `languages` |
| `rules.path_globs_json` | `path_globs` |
| `rules.payload_json` | `payload` |
| `rules.examples_json` | `examples` |
| `rules.source_pr_refs_json` | `source_pr_refs` |
| `findings.fingerprint` | **not** on HTTP `Finding` (matcher-only) |
| `job_events.payload_json` | `payload_json` (same name) |

**Added in the contract, not specified in the design prose**

- Error envelope `{ error: { code, message, details } }` and `ErrorCode`.
- `GET /api/jobs` wrapper `{ jobs, total }` (design only said query params).
- `POST /api/rules/:id/enable` and `/disable` (design already has PUT + CRUD).
- `GET /api/health` `{ ok, version }` shape (`version` = Gegenlesen `0.1.0`).
- `Finding.created_at` on HTTP (SQL has it; design example omitted it). **Keep it** — list/detail need a timestamp.

**Still missing as a schema file**

- `.gegenlesen/mined-rules.json` (miner output). Same objects as `Rule` with `provenance=mined`, `enabled=false`.
- Command-checker stdout JSONL (one `AgentFinding` per line).

**Swift contract is domain, not wire**

- `Job.reviewerSlot` encodes as `reviewer_slot` (SQL). HTTP DTOs (`JobListItem`, `JobDetail`) encode `reviewer_model_slot`. Do not return `Job` from a route.
- `RulePayload` is not `Codable` in the stub; PR 2 must implement untagged decode.
- `Finding.fingerprint` exists on the domain struct only.

---

## Conventions

| Topic | Rule |
| --- | --- |
| JSON keys | `snake_case`. Never camelCase on the wire. |
| Swift names | `camelCase` properties, explicit `CodingKeys`. |
| Timestamps | ISO-8601 UTC, suffix `Z`. Example: `2026-08-17T18:01:00Z`. |
| Job id | UUID v4, lowercase, hex + hyphens. |
| Finding id | `fnd_` + Crockford ULID. Host-assigned. Agent `id` is ignored. |
| Rule id | kebab-case `[a-z0-9][a-z0-9-]{1,126}`. |
| Corpus id | UUID v4. |
| SHA-256 | lowercase hex, 64 chars. CryptoKit of **file bytes**, never BSD `shasum`, never git blob SHA-1. |
| Git SHA | 40-char lowercase hex, or the sentinels `noparent` and empty-tree `4b825dc642cb6eb9a060e54bf8d69288fbee4904`. |
| Nulls | Omitted optional fields are `null` in responses, not missing, except OpenAPI `additionalProperties: false` objects. |
| Auth | None. No `Authorization` header. |
| IDs in paths | `:id` is the resource id. Unknown id → `404`. |

---

## Module graph

```
GegenlesenAPI (executable)
  ├── GegenlesenCore
  │     └── CLibArchive
  ├── GegenlesenDeterministic
  │     └── GegenlesenCore
  ├── GegenlesenAgent
  │     └── GegenlesenCore
  └── GegenlesenMiner
        ├── GegenlesenCore
        └── GegenlesenAgent
```

`Package.swift`: `// swift-tools-version: 6.0`. Products: executable `GegenlesenAPI`; libraries `GegenlesenCore`, `GegenlesenDeterministic`, `GegenlesenAgent`, `GegenlesenMiner`.

---

## Closed enums

These are the only legal string values on the wire and in SQLite.

```swift
enum JobStatus: String, Codable, CaseIterable {
    case queued, unpacking, identifying, selectingRules = "selecting_rules"
    case deterministic, reviewing, judging
    case succeeded, failed, cancelled
}

enum JobScope: String, Codable { case full, incremental }

enum ReviewerSlot: String, Codable { case modelA = "model_a", modelB = "model_b" }

enum Severity: String, Codable { case info, warning, error }

enum FindingPhase: String, Codable { case deterministic, agent }

enum JudgeVerdict: String, Codable { case keep, drop, downgrade, unavailable }

enum FindingLifecycle: String, Codable { case new, stillOpen = "still_open", resolved, relocated }

enum RuleKind: String, Codable { case deterministic, semantic }

enum RuleProvenance: String, Codable { case handwritten, mined }

enum FileChangeStatus: String, Codable { case added, modified, deleted, renamed }

enum DeterministicCheckerKind: String, Codable { case regex, denyApi = "deny_api", siblingTest = "sibling_test", command, openapiBreak = "openapi_break" }

enum EventLevel: String, Codable { case debug, info, warning, error }

enum AgentPhase: String, Codable { case review, judge, command, openapiBreak = "openapi_break", miner }

enum TranscriptPhase: String, Codable { case review, reviewA = "review_a", reviewB = "review_b", judge } // query param only

enum Language: String, Codable {
    case swift, typescript, javascript, python, go, rust, jvm
    case c, ruby, csharp, shell, yaml, json, markdown, other
}

enum ErrorCode: String, Codable {
    case badRequest = "bad_request"
    case notFound = "not_found"
    case conflict
    case payloadTooLarge = "payload_too_large"
    case unsupportedMediaType = "unsupported_media_type"
    case unprocessable
    case insufficientStorage = "insufficient_storage"
    case internal = "internal"
}
```

`JobStatus.isTerminal` = `{succeeded, failed, cancelled}`.
`JobStatus.isActive` = everything else (counts toward queued-archive 507).

Severity rank: `info = 0`, `warning = 1`, `error = 2`. Downgrade must strictly decrease rank.

---

## Type catalog (who owns what)

Value types are `struct`. Process-owned mutable state is `actor`. No reference-type domain models.

### `GegenlesenCore.Models`

| Type | Kind | File | Notes |
| --- | --- | --- | --- |
| `Job` | struct | `Models/Job.swift` | Row + computed `queuePosition` |
| `JobSummary` | struct | `Models/Job.swift` | `{new, still_open, resolved, relocated, dropped}` |
| `JobFile` | struct | `Models/JobFile.swift` | One changed path |
| `JobEvent` | struct | `Models/JobEvent.swift` | Append-only log row |
| `Finding` | struct | `Models/Finding.swift` | Persisted / API finding |
| `Rule` | struct | `Models/Rule.swift` | Handwritten or mined |
| `RulePayload` | enum | `Models/Rule.swift` | Associated values per checker / semantic |
| `CorpusItem` | struct | `Models/CorpusItem.swift` | Ingested historical PR |
| `ChangeSet` | struct | `Git/ChangeSet.swift` | Identified diff |
| `Hunk` | struct | `Git/ChangeSet.swift` | Optional; not persisted |
| `GegenlesenConfig` | struct | `Models/GegenlesenConfig.swift` | `config/gegenlesen.json` |
| `Limits` | struct | `Models/GegenlesenConfig.swift` | Nested |
| `Workspace` | struct | `Git/Workspace.swift` | Path helpers + `resolveForRead` |
| `JobID` / `FindingID` / `RuleID` | struct (RawRepresentable) | `Models/IDs.swift` | Newtype wrappers |

### `GegenlesenCore.Store`

| Type | Kind | Responsibility |
| --- | --- | --- |
| `Store` | actor | All SQLite. One GRDB `DatabasePool`. |
| `BlobStore` | struct | `var/blobs/**` paths; no SQL |
| `Migrations` | enum | `v1_initial` only |

### `GegenlesenCore.Jobs`

| Type | Kind | Responsibility |
| --- | --- | --- |
| `ReviewPipeline` | struct | Phase driver; calls unpack → identify → rules → det → agent → judge |
| `JobStateMachine` | enum | `func transition(from:event:) throws -> JobStatus` |
| `ReviewJobParameters` | struct | swift-jobs `JobParameters`, field `jobID: JobID` |
| `MineCorpusJobParameters` | struct | same, `corpusJobID` |
| `WorkspaceGCJobParameters` | struct | cron, no payload |
| `BootReconcile` | struct | `func run(store:docker:jobs:)` on start |
| `WorkspaceGCJob` | struct | 24h workspaces, 7d archives, 30d transcripts |

### `GegenlesenCore.Git` / `Findings` / `Rules`

| Type | Kind | Responsibility |
| --- | --- | --- |
| `ArchiveUnpacker` | struct | Two-pass libarchive |
| `ChangeSetIdentifier` | struct | Sources 1–5 in the design |
| `PathGlob` | struct | gitignore-style, last match wins |
| `LanguageMap` | enum | `static func language(forPath:)` |
| `RuleSelector` | struct | PR 5 dumb; PR 12 ranked |
| `PromptBudget` | struct | 6000 tokens, `chars/4` |
| `FindingMatcher` | struct | Incremental carry-forward + collapse |
| `JudgeMerge` | enum | `static func merge(candidates:judge:)` |
| `Fingerprint` | enum | `static func sha256(ruleID:path:snippet:)` |
| `Normalize` | enum | `static func whitespace(_:)` |

### `GegenlesenDeterministic`

| Type | Kind | Responsibility |
| --- | --- | --- |
| `DeterministicChecker` | protocol | `func check(file:rule:) throws -> [FindingDraft]` |
| `RegexChecker` | struct | Swift `Regex` |
| `DenyListChecker` | struct | Word-boundary regex per symbol |
| `SiblingTestChecker` | struct | Path existence |
| `OpenAPIBreakChecker` | struct | Runs `oasdiff` in the sandbox |
| `FindingDraft` | struct | Pre-persist finding (no host id yet) |
| `DeterministicEngine` | struct | Runs matching checkers; skips on throw |

### `GegenlesenAgent`

| Type | Kind | Responsibility |
| --- | --- | --- |
| `DockerRunner` | actor | `run(_:)` + watchdog `Task` + `kill` |
| `DockerRequest` | struct | image, name, argv, env, mounts, network, limits |
| `DockerResult` | struct | exit, stdout, stderr, timedOut, oom |
| `OpenCodeHTTPClient` | struct | `GET /global/health`, `POST /session`, `POST /session/:id/message`, abort, permissions |
| `OpenCodeInvocation` | struct | Starts `opencode serve` (fallback `opencode run`) |
| `OpenCodeConfig` | enum | `policyJSON(model:defaultAgent:)` |
| `Quarantine` | enum | `static func run(workspace:)` |
| `FindingsParser` | enum | Agent file → `[Finding]` + discards |
| `JudgeParser` | enum | Judge file → `JudgeFile` |
| `PromptRenderer` | struct | Writes `.gegenlesen/*` before docker |
| `SecretRedactor` | struct | `sk-`, `sk-ant-`, PEM, `xox*`, env dumps |
| `CommandChecker` | struct | Phase `.command` docker, no keys |

### `GegenlesenAPI`

| Type | Kind | Responsibility |
| --- | --- | --- |
| `App` | struct `@main` | bind check, boot, routes |
| `JobsRoute` | struct | multipart + CRUD-ish |
| `RulesRoute` | struct | CRUD + promote |
| `CorpusRoute` | struct | ingest + mine |
| `SettingsRoute` | struct | `GET /api/settings`, `GET /api/health` |
| `MetricsRoute` | struct | Prometheus text |
| `APIError` | struct | Wire error envelope |
| `CreateJobMeta` | struct | `meta` part |
| `JobDTO` / `FindingDTO` / `RuleDTO` | struct | Response bodies = models + `CodingKeys` |

### `GegenlesenMiner`

| Type | Kind | Responsibility |
| --- | --- | --- |
| `CorpusIngest` | struct | Unpack `item` parts |
| `MinerDedup` | enum | Normalized title / glob+FTS top-1 |
| `MinedRulesFile` | struct | `.gegenlesen/mined-rules.json` |

---

## Core structs (normative fields)

SQL column and HTTP key are the same unless the mapping table above says otherwise.

### `Job` (domain / SQL)

HTTP list/detail use `JobListItem` / `JobDetail`, **not** this struct. Those DTOs expose `reviewer_model_slot` and omit `updated_at`, `container_name`, `timings`, `archive_*`.

| Swift | SQL | Type |
| --- | --- | --- |
| `id` | `id` | `JobID` |
| `createdAt` | `created_at` | `Date` |
| `updatedAt` | `updated_at` | `Date` |
| `startedAt` | `started_at` | `Date?` |
| `finishedAt` | `finished_at` | `Date?` |
| `status` | `status` | `JobStatus` |
| `scope` | `scope` | `JobScope` |
| `parentJobID` | `parent_job_id` | `JobID?` |
| `title` | `title` | `String?` |
| `reviewerAModelID` | `reviewer_a_model_id` | `String` |
| `reviewerBModelID` | `reviewer_b_model_id` | `String` |
| `judgeModelID` | `judge_model_id` | `String` |
| `baseSHA` | `base_sha` | `String?` |
| `headSHA` | `head_sha` | `String?` |
| `defaultBranch` | `default_branch` | `String?` |
| `archiveSHA256` | `archive_sha256` | `String?` |
| `archiveBytes` | `archive_bytes` | `Int?` |
| `fileCount` | `file_count` | `Int?` |
| `errorMessage` | `error_message` | `String?` |
| `containerName` | `container_name` | `String?` |
| `timings` | `timings_json` | `JobTimings?` |
| `queuePosition` | `queue_position` | `Int?` (computed, not a column) |
| `summary` | `summary` | `JobSummary?` (computed) |

`JobSummary.dropped` counts rows with `judge_verdict == drop` only. `unavailable` is not dropped.

```swift
struct JobTimings: Codable {
    var unpackMS: Int?
    var identifyMS: Int?
    var deterministicMS: Int?
    var reviewMS: Int?
    var judgeMS: Int?
}

struct JobSummary: Codable, Equatable {
    var new: Int
    var stillOpen: Int       // json: still_open
    var resolved: Int
    var relocated: Int
    var dropped: Int
}
```

### `JobFile`

| Swift | JSON | Type |
| --- | --- | --- |
| `jobID` | `job_id` | `JobID` |
| `path` | `path` | `String` |
| `sha256` | `sha256` | `String?` |
| `status` | `status` | `FileChangeStatus` |
| `oldPath` | `old_path` | `String?` |
| `language` | `language` | `Language?` |
| `bytes` | `bytes` | `Int?` |

### `Finding`

| Swift | JSON | Type |
| --- | --- | --- |
| `id` | `id` | `FindingID` |
| `jobID` | `job_id` | `JobID` |
| `ruleID` | `rule_id` | `RuleID?` |
| `phase` | `phase` | `FindingPhase` |
| `severity` | `severity` | `Severity` |
| `title` | `title` | `String` |
| `message` | `message` | `String` |
| `filePath` | `file_path` | `String?` |
| `startLine` | `start_line` | `Int?` |
| `endLine` | `end_line` | `Int?` |
| `snippet` | `snippet` | `String?` |
| `agentRationale` | `agent_rationale` | `String?` |
| `judgeVerdict` | `judge_verdict` | `JudgeVerdict?` |
| `judgeSeverity` | `judge_severity` | `Severity?` |
| `judgeRationale` | `judge_rationale` | `String?` |
| `confidence` | `confidence` | `Double?` |
| `lifecycle` | `lifecycle` | `FindingLifecycle` |
| `parentFindingID` | `parent_finding_id` | `FindingID?` |
| `suggestedPatch` | `suggested_patch` | `String?` |
| `fingerprint` | `fingerprint` | `String?` (SQL only; **omit** on HTTP `Finding`) |
| `evidenceOK` | `evidence_ok` | `Bool?` |
| `createdAt` | `created_at` | `Date` |

Host-only fields (never taken from the agent file): `id`, `jobID`, `phase`, `lifecycle`, `parentFindingID`, `fingerprint`, `evidenceOK`, `judge*`.

### `Rule`

| Swift | JSON | Type |
| --- | --- | --- |
| `id` | `id` | `RuleID` |
| `title` | `title` | `String` |
| `severity` | `severity` | `Severity` |
| `kind` | `kind` | `RuleKind` |
| `enabled` | `enabled` | `Bool` |
| `deletedAt` | `deleted_at` | `Date?` |
| `provenance` | `provenance` | `RuleProvenance` |
| `languages` | `languages` | `[String]` (`*` allowed) |
| `pathGlobs` | `path_globs` | `[String]` |
| `payload` | `payload` | `RulePayload` |
| `examples` | `examples` | `[RuleExample]` |
| `sourcePRRefs` | `source_pr_refs` | `[String]` |
| `promotedFromRuleID` | `promoted_from_rule_id` | `RuleID?` |
| `body` | `body` (SQL column `body_md`) | `String` |
| `createdAt` | `created_at` | `Date` |
| `updatedAt` | `updated_at` | `Date` |

```swift
enum RulePayload: Codable, Equatable {
    case regex(pattern: String, flags: String?, message: String)
    case denyAPI(symbols: [String], message: String)
    case siblingTest(sourceGlob: String, testTemplate: String)
    case command(argv: [String], timeoutSec: Int)
    case openapiBreak(specGlobs: [String], failOn: String, message: String)
    case semantic(instruction: String, fewShots: [String])
}

struct RuleExample: Codable, Equatable {
    var path: String?
    var excerpt: String
    var note: String?
}
```

`RulePayload` JSON is **untagged** plus `checker` / `instruction`:

```json
{ "checker": "regex", "pattern": "...", "message": "..." }
{ "checker": "deny_api", "symbols": ["eval"], "message": "..." }
{ "checker": "sibling_test", "source_glob": "Sources/**/*.swift", "test_template": "{stem}Tests.swift" }
{ "checker": "command", "argv": ["python3", "tools/check.py"], "timeout_sec": 20 }
{ "instruction": "Flag N+1 queries.", "few_shots": [] }
```

Decode: if `instruction` is present → semantic; else switch on `checker`. `timeout_sec` is capped at 20.

### `ChangeSet`

```swift
struct ChangeSet: Equatable {
    var baseSHA: String
    var headSHA: String
    var patchRelativePath: String          // var/blobs/patches/{job}.patch
    var files: [JobFile]
    var source: Source
    enum Source: String { case embeddedDiff, git, bundle, multipartPatch, hashInterdiff }
}
```

### `CreateJobMeta` (`meta` multipart part)

```json
{
  "title": "rate-limiter: add token bucket",
  "scope": "full",
  "reviewer_model": "model_a",
  "parent_job_id": null,
  "base_ref": "main",
  "head_ref": "HEAD",
  "base_sha": null,
  "head_sha": null
}
```

| Field | Required | Rules |
| --- | --- | --- |
| `title` | no | Default = `git log -1 --format=%s` or archive filename |
| `scope` | yes | `full` \| `incremental` |
| `reviewer_model` | yes | `model_a` \| `model_b` |
| `parent_job_id` | if incremental | UUID of a **succeeded** parent with `base_sha`, `head_sha`, ≥1 `job_files` |
| `base_ref` / `head_ref` | no | Ignored if SHAs set |
| `base_sha` / `head_sha` | no | 40-char hex |

### `GegenlesenConfig`

Matches `config/gegenlesen.json`. Secrets are **env only**, never this file.

```swift
struct GegenlesenConfig: Codable {
    var bind: String                 // default 127.0.0.1
    var port: Int                    // 8080
    var dataDir: String              // var
    var models: ModelSlots           // model_a, model_b
    var judgeModel: String
    var opencodeImage: String        // gegenlesen/opencode-runner:0.1.0
    var limits: Limits
}

struct ModelSlots: Codable {
    var modelA: String               // json: model_a
    var modelB: String               // json: model_b
}

struct Limits: Codable {
    var archiveBytes: Int            // 104_857_600
    var queuedArchiveBytes: Int      // 2_147_483_648
    var agentTimeoutSec: Int         // 900
    var judgeTimeoutSec: Int         // 300
    var deterministicTimeoutSec: Int // 30
    var identifyTimeoutSec: Int      // 60
    var ruleTokenBudget: Int         // 6000
}
```

Env overrides: `GEGENLESEN_MODEL_A`, `GEGENLESEN_MODEL_B`, `GEGENLESEN_JUDGE_MODEL`, `GEGENLESEN_DATA_DIR`, `GEGENLESEN_BIND`, `GEGENLESEN_PORT`, `GEGENLESEN_ALLOW_REMOTE` (`0`/`1`), `GEGENLESEN_SKIP_AGENT`, `GEGENLESEN_CONFIG`.

---

## Protocols

```swift
protocol DeterministicChecker: Sendable {
    func check(file: JobFile, bytes: Data, workspace: Workspace, rule: Rule) throws -> [FindingDraft]
}

protocol JobQueue: Sendable {
    func pushReview(_ id: JobID) async throws
    func cancel(_ id: JobID) async
}

protocol DockerExecuting: Sendable {
    func run(_ request: DockerRequest) async throws -> DockerResult
    func kill(containerName: String) async
    func removeAll(prefix: String) async  // "gegenlesen-"
}
```

`FindingDraft` is a finding minus host `id` / judge fields. `FindingsParser` and the deterministic engine both produce drafts; `Store.insertFindings` assigns ULIDs.

---

## Function signatures (must match)

```swift
enum JobStateMachine {
    enum Event: Equatable {
        case dequeued
        case unpackOK, unpackFailed(String)
        case identifyOK, identifyFailed(String)
        case rulesOK, rulesFailed(String)
        case deterministicDone(newWork: Bool, skipAgent: Bool)
        case deterministicTimeout
        case reviewOK(validFindingCount: Int)
        case reviewFailed(String)
        case judgeFinished                 // always succeeds the job
        case cancel
        case processRestarted
    }
    static func transition(from: JobStatus, _ event: Event) throws -> JobStatus
}

enum Normalize {
    static func whitespace(_ s: String) -> String
    // 1) NFC  2) trim  3) \p{Z} | \n | \r | \t runs → single ASCII space
}

enum Fingerprint {
    static func sha256(ruleID: RuleID?, path: String, snippet: String) -> String
    // sha256(utf8(rule_id + "\n" + path + "\n" + normalize_ws(snippet)))
}

struct FindingMatcher {
    func carryForward(parent: [Finding], parentFiles: [JobFile], child: ChangeSet, workspace: Workspace) -> [Finding]
    func collapse(child: Finding, parents: [Finding], childFiles: [JobFile]) -> Finding?
}

enum JudgeMerge {
    static func merge(candidates: [Finding], judge: JudgeFile?) -> [Finding]
}

enum FindingsParser {
    static func parse(file: Data, workspace: Workspace, knownRuleIDs: Set<RuleID>, jobID: JobID) throws -> ParseResult
    struct ParseResult { var findings: [Finding]; var discarded: Int }
}

enum Quarantine {
    static func run(workspace: Workspace) throws
}

struct Workspace {
    func resolveForRead(_ filePath: String) -> URL?
}

actor DockerRunner: DockerExecuting {
    func run(_ request: DockerRequest) async throws -> DockerResult
}
```

`JobStateMachine` legal transitions (anything else throws):

| from | event | to |
| --- | --- | --- |
| `queued` | `dequeued` | `unpacking` |
| `queued` | `cancel` | `cancelled` |
| `queued` | `processRestarted` (and `startedAt != nil`) | `failed` |
| `unpacking` | `unpackOK` | `identifying` |
| `unpacking` | `unpackFailed` | `failed` |
| `identifying` | `identifyOK` | `selecting_rules` |
| `identifying` | `identifyFailed` | `failed` |
| `selecting_rules` | `rulesOK` | `deterministic` |
| `selecting_rules` | `rulesFailed` | `failed` |
| `deterministic` | `deterministicDone(newWork:false, _)` or `(_, skipAgent:true)` | `succeeded` |
| `deterministic` | `deterministicDone(newWork:true, skipAgent:false)` | `reviewing` |
| `deterministic` | `deterministicTimeout` | `failed` |
| `reviewing` | `reviewOK(0)` | `succeeded` |
| `reviewing` | `reviewOK(n>0)` | `judging` |
| `reviewing` | `reviewFailed` | `failed` |
| `judging` | `judgeFinished` | `succeeded` |
| any non-terminal | `cancel` | `cancelled` |

---

## HTTP API

Base: `http://127.0.0.1:8080`. All JSON `Content-Type: application/json; charset=utf-8` except multipart upload, NDJSON transcripts, and Prometheus text.

No auth. SPA fallback: any non-`/api` 404 → `frontend/dist/index.html`.

### Error envelope

Every 4xx/5xx JSON body:

```json
{
  "error": {
    "code": "unprocessable",
    "message": "parent_job_id must reference a succeeded job",
    "details": { "parent_job_id": "11111111-1111-1111-1111-111111111111" }
  }
}
```

| HTTP | `error.code` | When |
| --- | --- | --- |
| 400 | `bad_request` | missing `archive`/`meta`; `meta` not JSON; bad `scope`; incremental without `parent_job_id` |
| 404 | `not_found` | unknown job/rule/corpus id |
| 409 | `conflict` | cancel on terminal job; promote of already-handwritten |
| 413 | `payload_too_large` | archive part > `limits.archive_bytes` |
| 415 | `unsupported_media_type` | zip magic or `.zip` filename |
| 422 | `unprocessable` | unknown `reviewer_model`; bad parent; `meta` lacks both SHAs **and** no `patch` part |
| 507 | `insufficient_storage` | queued archive bytes would exceed 2 GiB |
| 500 | `internal` | unhandled |

Multipart parser abort size = `archive_bytes + 1 MiB`. Do not buffer then reject.

### Routes

| Method | Path | Request | Success |
| --- | --- | --- | --- |
| `GET` | `/api/health` | — | `200 { "ok": true, "version": "0.1.0" }` |
| `GET` | `/api/settings` | — | `200 SettingsDTO` (no secrets) |
| `GET` | `/api/metrics` | — | `200 text/plain` Prometheus |
| `POST` | `/api/jobs` | multipart `archive` + `meta` [+ `patch`] | `202 JobAccepted` |
| `GET` | `/api/jobs` | `limit` `offset` `status` | `200 { "jobs": [JobListItem], "total": n }` |
| `GET` | `/api/jobs/:id` | — | `200 JobDetail` |
| `GET` | `/api/jobs/:id/events` | — | `200 { "events": [JobEvent] }` |
| `GET` | `/api/jobs/:id/transcript` | `phase=review\|review_a\|review_b\|judge` | `200` NDJSON (redacted) |
| `POST` | `/api/jobs/:id/cancel` | — | `200 JobDetail` |
| `GET` | `/api/jobs/:id/feedback` | — | `200 { "feedback": [FindingFeedback] }` |
| `POST` | `/api/findings/:id/feedback` | `{ verdict, comment? }` or `{ reaction }` | `201` row, `200` reused `should_be_rule`, `204` reaction cleared |
| `POST` | `/api/jobs/:id/learn` | — | `202 { "job_id": "…" }` |
| `GET` | `/api/rules` | `enabled` `kind` `provenance` | `200 { "rules": [Rule] }` |
| `GET` | `/api/rules/:id` | — | `200 Rule` |
| `POST` | `/api/rules` | `RuleUpsert` | `201 Rule` |
| `PUT` | `/api/rules/:id` | `RuleUpsert` | `200 Rule` |
| `DELETE` | `/api/rules/:id` | — | `200 Rule` (soft: sets `deleted_at`) |
| `POST` | `/api/rules/:id/promote` | — | `201 Rule` (new handwritten id) |
| `POST` | `/api/rules/:id/enable` | — | `200 Rule` |
| `POST` | `/api/rules/:id/disable` | — | `200 Rule` |
| `GET` | `/api/corpus` | — | `200 { "items": [CorpusItem] }` |
| `POST` | `/api/corpus` | multipart repeatable `item` | `202 { "accepted": n }` |
| `POST` | `/api/corpus/mine` | `{ "item_ids": ["…"] }` optional | `202 { "job_id": "…" }` |
| `GET` | `/api/corpus/:id` | — | `200 CorpusItem` |

`GET /api/jobs` default `limit=50`, max 200, `offset=0`, newest `created_at` first.

`queue_position` = `COUNT(*) FROM jobs WHERE status='queued' AND created_at <= :this` (1-based), else `null`.

### `POST /api/jobs` success

```json
{
  "id": "3b1c0e6a-2d1f-4c8a-9a11-0f7d2c4b91aa",
  "status": "queued",
  "queue_position": 1
}
```

Preferred `pack-repo.sh` tarball with empty meta SHAs and no `patch` part is **202**. Missing change-set is a later job failure (`error_message=no_change_set`), not HTTP 422.

### `GET /api/jobs/:id`

See [`schemas/openapi.yaml`](../schemas/openapi.yaml) `JobDetail`. Includes `findings` and `events` arrays. List endpoint **omits** those arrays (`JobListItem`).

### `GET /api/settings`

```json
{
  "bind": "127.0.0.1",
  "port": 8080,
  "models": {
    "model_a": "openrouter/deepseek/deepseek-v4-flash",
    "model_b": "openrouter/google/gemini-3.7-flash"
  },
  "judge_model": "openrouter/openai/gpt-5.6-terra",
  "opencode_image": "gegenlesen/opencode-runner:0.1.0",
  "limits": {
    "archive_bytes": 104857600,
    "queued_archive_bytes": 2147483648,
    "agent_timeout_sec": 900,
    "judge_timeout_sec": 300,
    "deterministic_timeout_sec": 30,
    "identify_timeout_sec": 60,
    "rule_token_budget": 6000
  }
}
```

### `GET /api/health`

```json
{ "ok": true, "version": "0.1.0" }
```

`version` is the Gegenlesen release, not the OpenCode pin.

---

## Workspace file contract

Written under the unpacked job workspace. Paths are relative to workspace root.

| Path | Writer | Reader |
| --- | --- | --- |
| `.gegenlesen/diff.patch` | pack-repo or `ChangeSetIdentifier` | reviewer, host |
| `.gegenlesen/base_sha` / `head_sha` | pack-repo | identifier |
| `.gegenlesen/history.bundle` | pack-repo (optional) | identifier via `git fetch` |
| `.gegenlesen/rules.json` | `PromptRenderer` | reviewer |
| `.gegenlesen/files.json` | `PromptRenderer` | reviewer |
| `.gegenlesen/prompt.md` | `PromptRenderer` | reviewer `--file` |
| `.gegenlesen/prompt-judge.md` | `PromptRenderer` | judge `--file` |
| `.gegenlesen/parent-findings.json` | `PromptRenderer` | reviewer (incremental) |
| `.gegenlesen/findings.schema.json` | `PromptRenderer` | reviewer |
| `.gegenlesen/judge.schema.json` | `PromptRenderer` | judge |
| `.gegenlesen/findings.json` | **agent only** | host parser |
| `.gegenlesen/agent-findings.json` | host (copy of agent file) | blobs |
| `.gegenlesen/judge-input.json` | **host after parse** | judge `--file` |
| `.gegenlesen/judge.json` | **judge only** | host merge |
| `.gegenlesen/mined-rules.json` | miner | host ingest |
| `.gegenlesen/transcript.json` | entrypoint `opencode export --sanitize` | host |
| `.gegenlesen/quarantine/<orig>` | `Quarantine` (copy) | `resolveForRead` |
| `opencode.json.gegenlesen-disabled` | `Quarantine` (rename) | never loaded by OpenCode |

`files.json`:

```json
[{ "path": "Sources/A.swift", "status": "modified", "sha256": "…", "language": "swift", "old_path": null }]
```

---

## Agent / judge JSON (file contract)

Agent file **must** be `{ "findings": [ … ] }`. A bare array is a **file-level** failure → job `failed` if new work existed.

Host ignores agent `id`. After parse: assign `fnd_` ULID, compute `evidence_ok` + `actual_slice`, write `judge-input.json`. Judge `--file`s **that** file, never `findings.json`.

Per-item discard (file stays valid):

| Condition | Action |
| --- | --- |
| missing required field | discard |
| `severity` not in enum | discard |
| `end_line` < `start_line` | discard |
| `file_path` contains `..` or is absolute | discard |
| path missing after `resolveForRead` | discard |
| snippet empty after trim | discard |
| snippet > 4096 bytes | truncate, keep |
| extra keys | ignore, keep |
| `rule_id` unknown | keep, persist `rule_id=null` |
| more than 200 findings | keep first 200 |

Judge file: `{ "verdicts": [ { "finding_id", "verdict", "rationale", "severity"? } ] }`.

Merge: host-forced `drop` iff `evidence_ok == false`. Missing verdict → `keep`. Unknown `finding_id` → ignore (do not invent). Container fail → all `unavailable`, job still `succeeded`. Deterministic regex/deny/sibling never go to the judge. `command` JSONL and `phase=agent` do.

---

## Docker names and env

| Phase | `--name` | Network | Provider keys |
| --- | --- | --- | --- |
| review | `gegenlesen-review-${JOB_ID}` | `gegenlesen-egress` | yes |
| judge | `gegenlesen-judge-${JOB_ID}` | `gegenlesen-egress` | yes |
| command | `gegenlesen-cmd-${JOB_ID}-${RULE_ID}` | `none` | **no** |
| miner | `gegenlesen-mine-${CORPUS_JOB_ID}` | `gegenlesen-egress` | yes |

Set `jobs.container_name` **before** `docker run`.

---

## SQLite

Schema is in the design (`v1_initial`). No `settings` table. FTS5 `rules_fts(title, body_md, examples, payload)` contentless; insert mapping uses `examples_json` → `examples`, `payload_json` → `payload`.

`queue_position` and `summary` are **not** columns.

---

## Frontend types

`frontend/src/api.ts` imports [`docs/contracts/api.ts`](contracts/api.ts) (or a copy). Poll `GET /api/jobs/:id` every 2000 ms while `status` is non-terminal. Upload parent dropdown: `GET /api/jobs?status=succeeded`.

Pages: `/` jobs list, `/upload`, `/jobs/:id`, `/rules`, `/rules/:id`, `/corpus`.

---

## Agent cross-check checklist

An implementation is wrong if any of these fail:

1. Wire JSON uses `snake_case` and the enums in this file only.
2. `POST /api/jobs` preferred pack (no SHAs, no `patch` part) returns **202**.
3. HTTP **422** only when meta lacks both SHAs **and** there is no `patch` part.
4. Job id is UUID; finding id is `fnd_` + ULID assigned by the host.
5. Agent cannot write anything except the four `.gegenlesen` contract files.
6. Judge reads `judge-input.json` with host ids, `evidence_ok`, `actual_slice`.
7. `evidence_ok == false` ⇒ `judge_verdict=drop` even if the judge said keep.
8. Judge container failure ⇒ job `succeeded`, verdicts `unavailable`.
9. Incremental empty interdiff + no unmatched det hits ⇒ no `docker run`.
10. `chown 1000:1000` failure on Darwin does not fail the job; on Linux it does.
11. `opencode.json` is renamed `opencode.json.gegenlesen-disabled` before OpenCode starts.
12. Command checkers get no provider keys and `--network none`.
13. Job retries = 0. Boot reconcile kills `gegenlesen-*` and fails in-flight rows.
14. `GET /api/settings` never contains API keys.
15. Bind is loopback or process refuses to start without `GEGENLESEN_ALLOW_REMOTE=1`.
16. `summary.dropped` counts `judge_verdict=drop` only.
17. Fingerprint uses CryptoKit SHA-256 of `rule_id + "\n" + path + "\n" + normalize_ws(snippet)`.
18. Collapse matches parent `path` **and** `old_path`.
19. No `tar -xf`. Extract is libarchive two-pass.
20. OpenCode binary is `anomalyco/opencode`. Control is `opencode serve` HTTP on loopback. `opencode run` is fallback only. Never the archived Go CLI.
21. HTTP stack is Vapor. Persistence is GRDB. No Redis.
22. `openapi_break` uses `oasdiff` in the runner image, `--network none`, no HTTP spec URLs.
