import Foundation
import GegenlesenCore
import Vapor

struct CreateJobMeta: Content {
    var title: String?
    var scope: JobScope
    var parentJobID: JobID?
    var baseRef: String?
    var headRef: String?
    var baseSHA: String?
    var headSHA: String?
    var repository: String?

    enum CodingKeys: String, CodingKey {
        case title, scope
        case parentJobID = "parent_job_id"
        case baseRef = "base_ref"
        case headRef = "head_ref"
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case repository
    }
}

struct JobAccepted: Content {
    var id: JobID
    var status: JobStatus
    var queuePosition: Int

    enum CodingKeys: String, CodingKey {
        case id, status
        case queuePosition = "queue_position"
    }
}

struct HarvestIngestResponse: Content {
    var rules: Int
    var notes: Int
}

struct JobListResponse: Content {
    var jobs: [JobListItem]
    var total: Int
}

struct RepositoryListResponse: Content {
    var repositories: [String]
}

struct JobEventsResponse: Content {
    var events: [JobEventDTO]
}

struct FindingFeedbackListResponse: Content {
    var feedback: [FindingFeedbackDTO]
}

struct FindingFeedbackRequest: Content {
    var verdict: FeedbackVerdict?
    var reaction: String?
    var comment: String?
}

struct FindingFeedbackDTO: Content {
    var id: Int
    var findingID: FindingID
    var jobID: JobID
    var ts: Date
    var verdict: FeedbackVerdict
    var reaction: FeedbackReaction?
    var comment: String?
    var suggestedRuleID: RuleID?

    enum CodingKeys: String, CodingKey {
        case id
        case findingID = "finding_id"
        case jobID = "job_id"
        case ts, verdict, reaction, comment
        case suggestedRuleID = "suggested_rule_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(findingID, forKey: .findingID)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(ts, forKey: .ts)
        try container.encode(verdict, forKey: .verdict)
        try container.encodeNilIfNeeded(reaction, forKey: .reaction)
        try container.encodeNilIfNeeded(comment, forKey: .comment)
        try container.encodeNilIfNeeded(suggestedRuleID, forKey: .suggestedRuleID)
    }

    init(feedback: FindingFeedback) {
        self.id = feedback.id
        self.findingID = feedback.findingID
        self.jobID = feedback.jobID
        self.ts = feedback.ts
        self.verdict = feedback.verdict
        self.reaction = feedback.reaction
        self.comment = feedback.comment
        self.suggestedRuleID = feedback.suggestedRuleID
    }
}

struct JobListItem: Content {
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeNilIfNeeded(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encode(scope, forKey: .scope)
        try container.encodeNilIfNeeded(parentJobID, forKey: .parentJobID)
        try container.encodeNilIfNeeded(repository, forKey: .repository)
        try container.encode(reviewerAModelID, forKey: .reviewerAModelID)
        try container.encode(reviewerBModelID, forKey: .reviewerBModelID)
        try container.encode(judgeModelID, forKey: .judgeModelID)
        try container.encodeNilIfNeeded(baseSHA, forKey: .baseSHA)
        try container.encodeNilIfNeeded(headSHA, forKey: .headSHA)
        try container.encodeNilIfNeeded(queuePosition, forKey: .queuePosition)
        try container.encodeNilIfNeeded(summary, forKey: .summary)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeNilIfNeeded(startedAt, forKey: .startedAt)
        try container.encodeNilIfNeeded(finishedAt, forKey: .finishedAt)
        try container.encodeNilIfNeeded(errorMessage, forKey: .errorMessage)
    }

    static func from(_ job: Job, queuePosition: Int?, summary: JobSummary?) -> JobListItem {
        JobListItem(
            id: job.id,
            title: job.title,
            status: job.status,
            scope: job.scope,
            parentJobID: job.parentJobID,
            repository: job.repository,
            reviewerAModelID: job.reviewerAModelID,
            reviewerBModelID: job.reviewerBModelID,
            judgeModelID: job.judgeModelID,
            baseSHA: job.baseSHA,
            headSHA: job.headSHA,
            queuePosition: queuePosition,
            summary: summary,
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            errorMessage: job.errorMessage
        )
    }
}

struct JobDetail: Content {
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
    var findings: [FindingDTO]
    var events: [JobEventDTO]

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
        case findings, events
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeNilIfNeeded(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encode(scope, forKey: .scope)
        try container.encodeNilIfNeeded(parentJobID, forKey: .parentJobID)
        try container.encodeNilIfNeeded(repository, forKey: .repository)
        try container.encode(reviewerAModelID, forKey: .reviewerAModelID)
        try container.encode(reviewerBModelID, forKey: .reviewerBModelID)
        try container.encode(judgeModelID, forKey: .judgeModelID)
        try container.encodeNilIfNeeded(baseSHA, forKey: .baseSHA)
        try container.encodeNilIfNeeded(headSHA, forKey: .headSHA)
        try container.encodeNilIfNeeded(queuePosition, forKey: .queuePosition)
        try container.encodeNilIfNeeded(summary, forKey: .summary)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeNilIfNeeded(startedAt, forKey: .startedAt)
        try container.encodeNilIfNeeded(finishedAt, forKey: .finishedAt)
        try container.encodeNilIfNeeded(errorMessage, forKey: .errorMessage)
        try container.encode(findings, forKey: .findings)
        try container.encode(events, forKey: .events)
    }

    static func from(
        _ job: Job,
        queuePosition: Int?,
        summary: JobSummary?,
        findings: [Finding],
        events: [JobEvent]
    ) -> JobDetail {
        JobDetail(
            id: job.id,
            title: job.title,
            status: job.status,
            scope: job.scope,
            parentJobID: job.parentJobID,
            repository: job.repository,
            reviewerAModelID: job.reviewerAModelID,
            reviewerBModelID: job.reviewerBModelID,
            judgeModelID: job.judgeModelID,
            baseSHA: job.baseSHA,
            headSHA: job.headSHA,
            queuePosition: queuePosition,
            summary: summary,
            createdAt: job.createdAt,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
            errorMessage: job.errorMessage,
            findings: findings.map(FindingDTO.init(finding:)),
            events: events.map(JobEventDTO.init(event:))
        )
    }
}

struct JobEventDTO: Content {
    var id: Int
    var jobID: JobID
    var ts: Date
    var level: EventLevel
    var message: String
    var payloadJSON: String?

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case ts, level, message
        case payloadJSON = "payload_json"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(ts, forKey: .ts)
        try container.encode(level, forKey: .level)
        try container.encode(message, forKey: .message)
        try container.encodeNilIfNeeded(payloadJSON, forKey: .payloadJSON)
    }

    init(event: JobEvent) {
        self.id = event.id
        self.jobID = event.jobID
        self.ts = event.ts
        self.level = event.level
        self.message = event.message
        self.payloadJSON = event.payloadJSON
    }
}

struct FindingDTO: Content {
    var id: FindingID
    var jobID: JobID
    var ruleID: RuleID?
    var phase: FindingPhase
    var reviewerSlot: ReviewerSlot?
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
        case evidenceOK = "evidence_ok"
        case createdAt = "created_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(jobID, forKey: .jobID)
        try container.encodeNilIfNeeded(ruleID, forKey: .ruleID)
        try container.encode(phase, forKey: .phase)
        try container.encodeNilIfNeeded(reviewerSlot, forKey: .reviewerSlot)
        try container.encode(severity, forKey: .severity)
        try container.encode(title, forKey: .title)
        try container.encode(message, forKey: .message)
        try container.encodeNilIfNeeded(filePath, forKey: .filePath)
        try container.encodeNilIfNeeded(startLine, forKey: .startLine)
        try container.encodeNilIfNeeded(endLine, forKey: .endLine)
        try container.encodeNilIfNeeded(snippet, forKey: .snippet)
        try container.encodeNilIfNeeded(agentRationale, forKey: .agentRationale)
        try container.encodeNilIfNeeded(judgeVerdict, forKey: .judgeVerdict)
        try container.encodeNilIfNeeded(judgeSeverity, forKey: .judgeSeverity)
        try container.encodeNilIfNeeded(judgeRationale, forKey: .judgeRationale)
        try container.encodeNilIfNeeded(confidence, forKey: .confidence)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encodeNilIfNeeded(parentFindingID, forKey: .parentFindingID)
        try container.encodeNilIfNeeded(suggestedPatch, forKey: .suggestedPatch)
        try container.encodeNilIfNeeded(evidenceOK, forKey: .evidenceOK)
        try container.encode(createdAt, forKey: .createdAt)
    }

    init(finding: Finding) {
        self.id = finding.id
        self.jobID = finding.jobID
        self.ruleID = finding.ruleID
        self.phase = finding.phase
        self.reviewerSlot = finding.reviewerSlot
        self.severity = finding.severity
        self.title = finding.title
        self.message = finding.message
        self.filePath = finding.filePath
        self.startLine = finding.startLine
        self.endLine = finding.endLine
        self.snippet = finding.snippet
        self.agentRationale = finding.agentRationale
        self.judgeVerdict = finding.judgeVerdict
        self.judgeSeverity = finding.judgeSeverity
        self.judgeRationale = finding.judgeRationale
        self.confidence = finding.confidence
        self.lifecycle = finding.lifecycle
        self.parentFindingID = finding.parentFindingID
        self.suggestedPatch = finding.suggestedPatch
        self.evidenceOK = finding.evidenceOK
        self.createdAt = finding.createdAt
    }
}

extension KeyedEncodingContainer {
    mutating func encodeNilIfNeeded<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
