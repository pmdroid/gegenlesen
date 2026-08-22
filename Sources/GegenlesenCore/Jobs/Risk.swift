import Foundation

public enum RiskMode: String, Codable, Sendable, Equatable, CaseIterable {
    case off, shadow, enforce
}

public enum RiskVerdict: String, Codable, Sendable, Equatable, CaseIterable {
    case autoApprove = "auto_approve"
    case needsHuman = "needs_human"
}

public struct RiskReason: Codable, Sendable, Equatable {
    public var code: String
    public var detail: String
    public var findingID: FindingID?

    public init(code: String, detail: String, findingID: FindingID? = nil) {
        self.code = code
        self.detail = detail
        self.findingID = findingID
    }

    enum CodingKeys: String, CodingKey {
        case code, detail
        case findingID = "finding_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(detail, forKey: .detail)
        if let findingID {
            try container.encode(findingID, forKey: .findingID)
        } else {
            try container.encodeNil(forKey: .findingID)
        }
    }
}

public struct RiskAssessment: Codable, Sendable, Equatable {
    public var verdict: RiskVerdict
    public var mode: RiskMode
    public var reasons: [RiskReason]
    public var safeUnread: Bool?

    public init(
        verdict: RiskVerdict,
        mode: RiskMode,
        reasons: [RiskReason],
        safeUnread: Bool? = nil
    ) {
        self.verdict = verdict
        self.mode = mode
        self.reasons = reasons
        self.safeUnread = safeUnread
    }

    enum CodingKeys: String, CodingKey {
        case verdict, mode, reasons
        case safeUnread = "safe_unread"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(verdict, forKey: .verdict)
        try container.encode(mode, forKey: .mode)
        try container.encode(reasons, forKey: .reasons)
        if let safeUnread {
            try container.encode(safeUnread, forKey: .safeUnread)
        } else {
            try container.encodeNil(forKey: .safeUnread)
        }
    }
}

public struct RiskConfig: Codable, Sendable, Equatable {
    public var mode: RiskMode
    public var maxFiles: Int
    public var maxLines: Int
    public var sensitiveGlobs: [String]

    public static let v1 = RiskConfig(
        mode: .shadow,
        maxFiles: 5,
        maxLines: 200,
        sensitiveGlobs: [
            "**/auth/**",
            "**/Auth/**",
            "**/*secret*",
            "**/.env",
            "**/.env.*",
            "**/migrations/**",
            "**/.github/workflows/**",
            "**/Dockerfile",
            "**/Dockerfile.*",
            "**/*.pem",
            "**/*.key",
            "**/payments/**",
            "**/crypto/**",
            "**/compose.yaml",
            "**/compose.yml",
            "**/docker-compose.yaml",
            "**/docker-compose.yml",
        ]
    )

    enum CodingKeys: String, CodingKey {
        case mode
        case maxFiles = "max_files"
        case maxLines = "max_lines"
        case sensitiveGlobs = "sensitive_globs"
    }

    public init(
        mode: RiskMode = RiskConfig.v1.mode,
        maxFiles: Int = RiskConfig.v1.maxFiles,
        maxLines: Int = RiskConfig.v1.maxLines,
        sensitiveGlobs: [String] = RiskConfig.v1.sensitiveGlobs
    ) {
        self.mode = mode
        self.maxFiles = max(0, maxFiles)
        self.maxLines = max(0, maxLines)
        self.sensitiveGlobs = sensitiveGlobs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decodeIfPresent(RiskMode.self, forKey: .mode) ?? Self.v1.mode,
            maxFiles: try container.decodeIfPresent(Int.self, forKey: .maxFiles) ?? Self.v1.maxFiles,
            maxLines: try container.decodeIfPresent(Int.self, forKey: .maxLines) ?? Self.v1.maxLines,
            sensitiveGlobs: try container.decodeIfPresent([String].self, forKey: .sensitiveGlobs)
                ?? Self.v1.sensitiveGlobs
        )
    }
}

public enum RiskGate: Sendable {
    public struct Input: Sendable {
        public var scope: JobScope
        public var changeSetSource: ChangeSet.Source?
        public var files: [JobFile]
        public var findings: [Finding]
        public var rules: [Rule]
        public var changedLines: Int?
        public var reviewersInvoked: Bool
        public var validReviewerFiles: Int
        public var judgeUnavailable: Bool
        public var config: RiskConfig

        public init(
            scope: JobScope,
            changeSetSource: ChangeSet.Source?,
            files: [JobFile],
            findings: [Finding],
            rules: [Rule],
            changedLines: Int?,
            reviewersInvoked: Bool,
            validReviewerFiles: Int,
            judgeUnavailable: Bool,
            config: RiskConfig
        ) {
            self.scope = scope
            self.changeSetSource = changeSetSource
            self.files = files
            self.findings = findings
            self.rules = rules
            self.changedLines = changedLines
            self.reviewersInvoked = reviewersInvoked
            self.validReviewerFiles = validReviewerFiles
            self.judgeUnavailable = judgeUnavailable
            self.config = config
        }
    }

    public static func evaluate(_ input: Input) -> RiskAssessment {
        var reasons: [RiskReason] = []
        if input.scope == .incremental {
            reasons.append(RiskReason(
                code: "incremental_scope",
                detail: "incremental jobs are not auto-approvable"
            ))
        }
        if input.changeSetSource == .hashInterdiff {
            reasons.append(RiskReason(
                code: "degraded_change_set",
                detail: "change-set used hash interdiff, not git history"
            ))
        }
        if input.config.sensitiveGlobs.isEmpty {
            reasons.append(RiskReason(
                code: "sensitive_globs_unconfigured",
                detail: "risk.sensitive_globs is empty; fail closed"
            ))
        }
        if input.files.count > input.config.maxFiles {
            reasons.append(RiskReason(
                code: "too_many_files",
                detail: "\(input.files.count) files exceed max_files \(input.config.maxFiles)"
            ))
        }
        if let lines = input.changedLines, lines > input.config.maxLines {
            reasons.append(RiskReason(
                code: "too_many_lines",
                detail: "\(lines) changed lines exceed max_lines \(input.config.maxLines)"
            ))
        }
        if !input.reviewersInvoked, !input.files.isEmpty {
            reasons.append(RiskReason(
                code: "reviewers_skipped",
                detail: "reviewers did not run on a non-empty change"
            ))
        }
        if input.reviewersInvoked, input.validReviewerFiles < 2 {
            reasons.append(RiskReason(
                code: "reviewer_file_missing",
                detail: "\(input.validReviewerFiles) of 2 reviewer files were valid"
            ))
        }
        if input.judgeUnavailable {
            reasons.append(RiskReason(
                code: "judge_unavailable",
                detail: "judge container failed or wrote an invalid file"
            ))
        }

        let sensitive = PathGlob(input.config.sensitiveGlobs)
        for file in input.files {
            if sensitive.matches(file.path) || file.oldPath.map({ sensitive.matches($0) }) == true {
                reasons.append(RiskReason(
                    code: "sensitive_path",
                    detail: "touched \(file.path)"
                ))
                break
            }
        }

        let openAPI = Set(input.rules.compactMap { rule -> RuleID? in
            if case .openapiBreak = rule.payload { return rule.id }
            return nil
        })

        for finding in input.findings {
            if finding.evidenceOK == false {
                reasons.append(RiskReason(
                    code: "unverifiable_finding",
                    detail: "evidence_ok is false",
                    findingID: finding.id
                ))
            }
            if finding.lifecycle == .resolved { continue }
            if finding.judgeVerdict == .drop { continue }
            if finding.judgeVerdict == .unavailable {
                if !reasons.contains(where: { $0.code == "judge_unavailable" }) {
                    reasons.append(RiskReason(
                        code: "judge_unavailable",
                        detail: "judge_verdict is unavailable",
                        findingID: finding.id
                    ))
                }
                continue
            }
            if let ruleID = finding.ruleID, openAPI.contains(ruleID) {
                reasons.append(RiskReason(
                    code: "openapi_break",
                    detail: finding.title,
                    findingID: finding.id
                ))
            }
            let severity = finding.judgeSeverity ?? finding.severity
            switch severity {
            case .error:
                reasons.append(RiskReason(
                    code: "kept_error",
                    detail: finding.title,
                    findingID: finding.id
                ))
            case .warning:
                reasons.append(RiskReason(
                    code: "kept_warning",
                    detail: finding.title,
                    findingID: finding.id
                ))
            case .info:
                break
            }
        }

        let verdict: RiskVerdict = reasons.isEmpty ? .autoApprove : .needsHuman
        return RiskAssessment(verdict: verdict, mode: input.config.mode, reasons: reasons)
    }

    public static func changedLines(in patch: Data?) -> Int? {
        guard let patch, !patch.isEmpty, let text = String(data: patch, encoding: .utf8) else {
            return nil
        }
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("@@") {
                continue
            }
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") || line == "+++" || line == "---" {
                continue
            }
            if line.hasPrefix("+") || line.hasPrefix("-") {
                count += 1
            }
        }
        return count
    }

    public static func encode(_ assessment: RiskAssessment) -> String? {
        guard let data = try? JSONEncoder().encode(assessment) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ raw: String?) -> RiskAssessment? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RiskAssessment.self, from: data)
    }
}
