// GegenlesenTypes.swift
// Documentation contract — copy into Sources/GegenlesenCore/Models during PR 2.
// Not part of Package.swift yet. JSON keys are snake_case via CodingKeys.
// Source of truth: docs/technical-plan.md + schemas/*.json

import Foundation

// MARK: - IDs

struct JobID: RawRepresentable, Hashable, Codable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

struct FindingID: RawRepresentable, Hashable, Codable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    /// Host-assigned. Format: `fnd_` + Crockford ULID.
    static func generate() -> FindingID { fatalError("implement in PR 2") }
}

struct RuleID: RawRepresentable, Hashable, Codable, Sendable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Enums (wire strings)

enum JobStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case unpacking
    case identifying
    case selectingRules = "selecting_rules"
    case deterministic
    case reviewing
    case judging
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }

    var isActive: Bool { !isTerminal }
}

enum JobScope: String, Codable, Sendable {
    case full
    case incremental
}

enum ReviewerSlot: String, Codable, Sendable {
    case modelA = "model_a"
    case modelB = "model_b"
}

enum Severity: String, Codable, Sendable {
    case info, warning, error

    var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    var nextLower: Severity? {
        switch self {
        case .error: .warning
        case .warning: .info
        case .info: nil
        }
    }
}

enum FindingPhase: String, Codable, Sendable {
    case deterministic
    case agent
}

enum JudgeVerdict: String, Codable, Sendable {
    case keep, drop, downgrade, unavailable
}

enum FindingLifecycle: String, Codable, Sendable {
    case new
    case stillOpen = "still_open"
    case resolved
    case relocated
}

enum RuleKind: String, Codable, Sendable {
    case deterministic
    case semantic
}

enum RuleProvenance: String, Codable, Sendable {
    case handwritten
    case mined
    case suggested
}

enum FeedbackVerdict: String, Codable, Sendable {
    case agree, disagree, comment, shouldBeRule = "should_be_rule"
}

enum FeedbackReaction: String, Codable, Sendable {
    case thumbsUp = "thumbs_up"
    case thumbsDown = "thumbs_down"

    static func normalize(_ raw: String) -> FeedbackReaction? {
        switch raw {
        case "thumbs_up", "+1", "👍": return .thumbsUp
        case "thumbs_down", "-1", "👎": return .thumbsDown
        default: return nil
        }
    }

    var verdict: FeedbackVerdict {
        switch self {
        case .thumbsUp: return .agree
        case .thumbsDown: return .disagree
        }
    }
}

enum FileChangeStatus: String, Codable, Sendable {
    case added, modified, deleted, renamed
}

enum DeterministicCheckerKind: String, Codable, Sendable {
    case regex
    case denyApi = "deny_api"
    case siblingTest = "sibling_test"
    case command
    case openapiBreak = "openapi_break"
    case riskWeight = "risk_weight"
}

enum EventLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

enum RiskMode: String, Codable, Sendable {
    case off, shadow, enforce
}

enum RiskVerdict: String, Codable, Sendable {
    case autoApprove = "auto_approve"
    case needsHuman = "needs_human"
}

enum AgentPhase: String, Codable, Sendable {
    case review, judge, command, miner
}

enum TranscriptPhase: String, Codable, Sendable {
    case review
    case reviewA = "review_a"
    case reviewB = "review_b"
    case judge
    case mine
    case suggestionJudge = "suggestion_judge"
}

enum Language: String, Codable, Sendable {
    case swift, typescript, javascript, python, go, rust, jvm
    case c, ruby, csharp, shell, yaml, json, markdown, other
}

enum ErrorCode: String, Codable, Sendable {
    case badRequest = "bad_request"
    case notFound = "not_found"
    case forbidden
    case conflict
    case payloadTooLarge = "payload_too_large"
    case unsupportedMediaType = "unsupported_media_type"
    case unprocessable
    case insufficientStorage = "insufficient_storage"
    case `internal` = "internal"
}

// MARK: - Domain

struct Job: Codable, Sendable, Equatable {
    var id: JobID
    var createdAt: Date
    var updatedAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var status: JobStatus
    var scope: JobScope
    var parentJobID: JobID?
    var title: String?
    var reviewerAModelID: String
    var reviewerBModelID: String
    var judgeModelID: String
    var baseSHA: String?
    var headSHA: String?
    var defaultBranch: String?
    var archiveSHA256: String?
    var archiveBytes: Int?
    var fileCount: Int?
    var errorMessage: String?
    var containerName: String?
    var timings: JobTimings?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case status, scope
        case parentJobID = "parent_job_id"
        case title
        case reviewerAModelID = "reviewer_a_model_id"
        case reviewerBModelID = "reviewer_b_model_id"
        case judgeModelID = "judge_model_id"
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case defaultBranch = "default_branch"
        case archiveSHA256 = "archive_sha256"
        case archiveBytes = "archive_bytes"
        case fileCount = "file_count"
        case errorMessage = "error_message"
        case containerName = "container_name"
        case timings = "timings_json"
    }
}

struct JobTimings: Codable, Sendable, Equatable {
    var unpackMS: Int?
    var identifyMS: Int?
    var deterministicMS: Int?
    var reviewMS: Int?
    var judgeMS: Int?

    enum CodingKeys: String, CodingKey {
        case unpackMS = "unpack_ms"
        case identifyMS = "identify_ms"
        case deterministicMS = "deterministic_ms"
        case reviewMS = "review_ms"
        case judgeMS = "judge_ms"
    }
}

struct JobSummary: Codable, Sendable, Equatable {
    var new: Int
    var stillOpen: Int
    var resolved: Int
    var relocated: Int
    var dropped: Int

    enum CodingKeys: String, CodingKey {
        case new
        case stillOpen = "still_open"
        case resolved, relocated, dropped
    }
}

struct JobFile: Codable, Sendable, Equatable {
    var jobID: JobID
    var path: String
    var sha256: String?
    var status: FileChangeStatus
    var oldPath: String?
    var language: Language?
    var bytes: Int?

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case path, sha256, status
        case oldPath = "old_path"
        case language, bytes
    }
}

struct JobEvent: Codable, Sendable, Equatable {
    var id: Int
    var jobID: JobID
    var ts: Date
    var level: EventLevel
    var message: String
    var payload: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case ts, level, message
        case payload = "payload_json"
    }
}

struct Finding: Codable, Sendable, Equatable {
    var id: FindingID
    var jobID: JobID
    var ruleID: RuleID?
    var phase: FindingPhase
    var severity: Severity
    var title: String
    var message: String
    var filePath: String?
    var startLine: Int?
    var endLine: Int?
    var snippet: String?
    var agentRationale: String?
    var judgeVerdict: JudgeVerdict?
    var judgeSeverity: Severity?
    var judgeRationale: String?
    var confidence: Double?
    var lifecycle: FindingLifecycle
    var parentFindingID: FindingID?
    var suggestedPatch: String?
    var fingerprint: String?
    var evidenceOK: Bool?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case ruleID = "rule_id"
        case phase
        case reviewerSlot = "reviewer_slot"
        case severity, title, message
        case filePath = "file_path"
        case startLine = "start_line"
        case endLine = "end_line"
        case snippet
        case agentRationale = "agent_rationale"
        case judgeVerdict = "judge_verdict"
        case judgeSeverity = "judge_severity"
        case judgeRationale = "judge_rationale"
        case confidence, lifecycle
        case parentFindingID = "parent_finding_id"
        case suggestedPatch = "suggested_patch"
        case fingerprint
        case evidenceOK = "evidence_ok"
        case createdAt = "created_at"
    }
}

struct FindingDraft: Sendable, Equatable {
    var ruleID: RuleID?
    var phase: FindingPhase
    var severity: Severity
    var title: String
    var message: String
    var filePath: String
    var startLine: Int
    var endLine: Int
    var snippet: String
    var rationale: String?
    var confidence: Double?
    var suggestedPatch: String?
}

struct RuleExample: Codable, Sendable, Equatable {
    var path: String?
    var excerpt: String
    var note: String?
}

enum RulePayload: Equatable, Sendable {
    case regex(pattern: String, flags: String?, message: String)
    case denyAPI(symbols: [String], message: String)
    case siblingTest(sourceGlob: String, testTemplate: String)
    case command(argv: [String], timeoutSec: Int)
    case openapiBreak(specGlobs: [String], failOn: String, message: String)
    case riskWeight(weight: Int, match: String, veto: Bool)
    case semantic(instruction: String, fewShots: [String])
}

struct Rule: Codable, Sendable, Equatable {
    var id: RuleID
    var title: String
    var severity: Severity
    var kind: RuleKind
    var enabled: Bool
    var deletedAt: Date?
    var provenance: RuleProvenance
    var languages: [String]
    var pathGlobs: [String]
    var repository: String?
    var payload: RulePayload
    var examples: [RuleExample]
    var sourcePRRefs: [String]
    var promotedFromRuleID: RuleID?
    var body: String
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, severity, kind, enabled
        case deletedAt = "deleted_at"
        case provenance, languages
        case pathGlobs = "path_globs"
        case repository
        case payload, examples
        case sourcePRRefs = "source_pr_refs"
        case promotedFromRuleID = "promoted_from_rule_id"
        case body
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct CorpusItem: Codable, Sendable, Equatable {
    var id: String
    var sourceLabel: String
    var title: String?
    var body: String?
    var commentsJSON: String?
    var patchRelpath: String
    var minedAt: Date?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sourceLabel = "source_label"
        case title, body
        case commentsJSON = "comments_json"
        case patchRelpath = "patch_relpath"
        case minedAt = "mined_at"
        case createdAt = "created_at"
    }
}

struct ChangeSet: Sendable, Equatable {
    var baseSHA: String
    var headSHA: String
    var patchRelativePath: String
    var files: [JobFile]
    var source: Source

    enum Source: String, Sendable {
        case embeddedDiff
        case git
        case bundle
        case multipartPatch
        case hashInterdiff
    }
}

// MARK: - Config

struct GegenlesenConfig: Codable, Sendable, Equatable {
    var bind: String
    var port: Int
    var dataDir: String
    var models: ModelSlots
    var judgeModel: String
    var opencodeImage: String
    var scannerImage: String
    var limits: Limits

    enum CodingKeys: String, CodingKey {
        case bind, port
        case dataDir = "data_dir"
        case models
        case judgeModel = "judge_model"
        case opencodeImage = "opencode_image"
        case scannerImage = "scanner_image"
        case limits
    }
}

struct ModelSlots: Codable, Sendable, Equatable {
    var modelA: String
    var modelB: String

    enum CodingKeys: String, CodingKey {
        case modelA = "model_a"
        case modelB = "model_b"
    }
}

struct Limits: Codable, Sendable, Equatable {
    var archiveBytes: Int
    var queuedArchiveBytes: Int
    var agentTimeoutSec: Int
    var judgeTimeoutSec: Int
    var deterministicTimeoutSec: Int
    var identifyTimeoutSec: Int
    var ruleTokenBudget: Int
    var learnIntervalMinutes: Int
    var scannerTimeoutSec: Int

    enum CodingKeys: String, CodingKey {
        case archiveBytes = "archive_bytes"
        case queuedArchiveBytes = "queued_archive_bytes"
        case agentTimeoutSec = "agent_timeout_sec"
        case judgeTimeoutSec = "judge_timeout_sec"
        case deterministicTimeoutSec = "deterministic_timeout_sec"
        case identifyTimeoutSec = "identify_timeout_sec"
        case ruleTokenBudget = "rule_token_budget"
        case learnIntervalMinutes = "learn_interval_minutes"
        case scannerTimeoutSec = "scanner_timeout_sec"
    }

    static let v1 = Limits(
        archiveBytes: 104_857_600,
        queuedArchiveBytes: 2_147_483_648,
        agentTimeoutSec: 900,
        judgeTimeoutSec: 300,
        deterministicTimeoutSec: 30,
        identifyTimeoutSec: 60,
        ruleTokenBudget: 6000,
        learnIntervalMinutes: 15,
        scannerTimeoutSec: 120
    )
}

// MARK: - HTTP DTOs

struct APIErrorBody: Codable, Sendable, Equatable {
    var error: APIError
}

struct APIError: Codable, Sendable, Equatable {
    var code: ErrorCode
    var message: String
    var details: [String: String]?
}

struct HealthDTO: Codable, Sendable, Equatable {
    var ok: Bool
    var version: String
}

struct SettingsDTO: Codable, Sendable, Equatable {
    var bind: String
    var port: Int
    var models: ModelSlots
    var judgeModel: String
    var opencodeImage: String
    var scannerImage: String
    var limits: Limits
    var openrouterConfigured: Bool
    var risk: RiskConfig

    enum CodingKeys: String, CodingKey {
        case bind, port, models
        case judgeModel = "judge_model"
        case opencodeImage = "opencode_image"
        case scannerImage = "scanner_image"
        case limits
        case openrouterConfigured = "openrouter_configured"
        case risk
    }
}

struct RiskConfig: Codable, Sendable, Equatable {
    var mode: RiskMode
    var appetite: Int
    var maxFiles: Int
    var maxLines: Int
    var sensitiveGlobs: [String]

    enum CodingKeys: String, CodingKey {
        case mode, appetite
        case maxFiles = "max_files"
        case maxLines = "max_lines"
        case sensitiveGlobs = "sensitive_globs"
    }
}

struct CreateJobMeta: Codable, Sendable, Equatable {
    var title: String?
    var scope: JobScope
    var reviewerModel: ReviewerSlot? // ignored; both slots always run
    var parentJobID: JobID?
    var baseRef: String?
    var headRef: String?
    var baseSHA: String?
    var headSHA: String?
    var repository: String?

    enum CodingKeys: String, CodingKey {
        case title, scope
        case reviewerModel = "reviewer_model"
        case parentJobID = "parent_job_id"
        case baseRef = "base_ref"
        case headRef = "head_ref"
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case repository
    }
}

struct JobAccepted: Codable, Sendable, Equatable {
    var id: JobID
    var status: JobStatus
    var queuePosition: Int

    enum CodingKeys: String, CodingKey {
        case id, status
        case queuePosition = "queue_position"
    }
}

struct JobListItem: Codable, Sendable, Equatable {
    var id: JobID
    var title: String?
    var status: JobStatus
    var scope: JobScope
    var parentJobID: JobID?
    var repository: String?
    var reviewerAModelID: String
    var reviewerBModelID: String
    var judgeModelID: String
    var baseSHA: String?
    var headSHA: String?
    var queuePosition: Int?
    var summary: JobSummary?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var errorMessage: String?
    var risk: RiskAssessment?

    enum CodingKeys: String, CodingKey {
        case id, title, status, scope
        case parentJobID = "parent_job_id"
        case repository
        case reviewerAModelID = "reviewer_a_model_id"
        case reviewerBModelID = "reviewer_b_model_id"
        case judgeModelID = "judge_model_id"
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case queuePosition = "queue_position"
        case summary
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case errorMessage = "error_message"
        case risk
    }
}

struct RiskReason: Codable, Sendable, Equatable {
    var code: String
    var detail: String
    var findingID: FindingID?
    var points: Int?

    enum CodingKeys: String, CodingKey {
        case code, detail, points
        case findingID = "finding_id"
    }
}

struct RiskAssessment: Codable, Sendable, Equatable {
    var verdict: RiskVerdict
    var mode: RiskMode
    var score: Int
    var appetite: Int
    var reasons: [RiskReason]
    var safeUnread: Bool?

    enum CodingKeys: String, CodingKey {
        case verdict, mode, score, appetite, reasons
        case safeUnread = "safe_unread"
    }
}

struct JobDetail: Codable, Sendable, Equatable {
    var id: JobID
    var title: String?
    var status: JobStatus
    var scope: JobScope
    var parentJobID: JobID?
    var repository: String?
    var reviewerAModelID: String
    var reviewerBModelID: String
    var judgeModelID: String
    var baseSHA: String?
    var headSHA: String?
    var queuePosition: Int?
    var summary: JobSummary?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var errorMessage: String?
    var risk: RiskAssessment?
    var findings: [Finding]
    var events: [JobEvent]

    enum CodingKeys: String, CodingKey {
        case id, title, status, scope
        case parentJobID = "parent_job_id"
        case repository
        case reviewerAModelID = "reviewer_a_model_id"
        case reviewerBModelID = "reviewer_b_model_id"
        case judgeModelID = "judge_model_id"
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case queuePosition = "queue_position"
        case summary
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case errorMessage = "error_message"
        case risk
        case findings, events
    }
}

struct JobListResponse: Codable, Sendable, Equatable {
    var jobs: [JobListItem]
    var total: Int
}

struct RuleListResponse: Codable, Sendable, Equatable {
    var rules: [Rule]
}

struct CorpusListResponse: Codable, Sendable, Equatable {
    var items: [CorpusItem]
}

struct CorpusAccepted: Codable, Sendable, Equatable {
    var accepted: Int
}

struct MineRequest: Codable, Sendable, Equatable {
    var itemIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case itemIDs = "item_ids"
    }
}

struct MineAccepted: Codable, Sendable, Equatable {
    var jobID: JobID

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
    }
}

// MARK: - Agent / judge files

struct AgentFindingsFile: Codable, Sendable, Equatable {
    var findings: [AgentFinding]
}

struct AgentFinding: Codable, Sendable, Equatable {
    var id: String?
    var ruleID: RuleID?
    var severity: Severity
    var title: String
    var message: String
    var filePath: String
    var startLine: Int
    var endLine: Int
    var snippet: String
    var rationale: String?
    var confidence: Double?
    var suggestedPatch: String?

    enum CodingKeys: String, CodingKey {
        case id
        case ruleID = "rule_id"
        case severity, title, message
        case filePath = "file_path"
        case startLine = "start_line"
        case endLine = "end_line"
        case snippet, rationale, confidence
        case suggestedPatch = "suggested_patch"
    }
}

struct JudgeInputFile: Codable, Sendable, Equatable {
    var candidates: [JudgeCandidate]
}

struct JudgeCandidate: Codable, Sendable, Equatable {
    var id: FindingID
    var ruleID: RuleID?
    var severity: Severity
    var title: String
    var message: String
    var filePath: String
    var startLine: Int
    var endLine: Int
    var snippet: String
    var rationale: String?
    var phase: FindingPhase
    var evidenceOK: Bool
    var actualSlice: String

    enum CodingKeys: String, CodingKey {
        case id
        case ruleID = "rule_id"
        case severity, title, message
        case filePath = "file_path"
        case startLine = "start_line"
        case endLine = "end_line"
        case snippet, rationale, phase
        case evidenceOK = "evidence_ok"
        case actualSlice = "actual_slice"
    }
}

struct JudgeFile: Codable, Sendable, Equatable {
    var verdicts: [JudgeVerdictRow]
}

struct JudgeVerdictRow: Codable, Sendable, Equatable {
    var findingID: FindingID
    var verdict: JudgeVerdict
    var rationale: String
    var severity: Severity?

    enum CodingKeys: String, CodingKey {
        case findingID = "finding_id"
        case verdict, rationale, severity
    }
}

// MARK: - Docker / jobs

struct DockerRequest: Sendable {
    var name: String
    var image: String
    var argv: [String]
    var env: [String: String]
    var network: String?
    var workdir: String
    var binds: [Bind]
    var cpus: String
    var memory: String
    var pidsLimit: Int
    var timeout: Duration
    var injectProviderKeys: Bool

    struct Bind: Sendable {
        var source: String
        var dest: String
        var readOnly: Bool
    }
}

struct DockerResult: Sendable {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
    var oom: Bool
}

struct ReviewJobParameters: Sendable {
    static let jobName = "gegenlesen.review"
    var jobID: JobID
}

struct MineCorpusJobParameters: Sendable {
    static let jobName = "gegenlesen.mine"
    var corpusJobID: JobID
}

struct WorkspaceGCJobParameters: Sendable {
    static let jobName = "gegenlesen.gc"
}

// MARK: - Protocols

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
    func removeAll(prefix: String) async
}

struct Workspace: Sendable {
    var root: URL
    func resolveForRead(_ filePath: String) -> URL? { nil }
}
