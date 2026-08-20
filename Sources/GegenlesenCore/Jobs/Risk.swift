import Foundation

public enum RiskMode: String, Codable, Sendable, Equatable, CaseIterable {
    case off, shadow, enforce
}

public enum RiskVerdict: String, Codable, Sendable, Equatable, CaseIterable {
    case autoApprove = "auto_approve"
    case needsHuman = "needs_human"
}

public enum RiskWeightMatch: String, Codable, Sendable, Equatable {
    case any
    case all
}

public struct RiskReason: Codable, Sendable, Equatable {
    public var code: String
    public var detail: String
    public var findingID: FindingID?
    public var points: Int?

    public init(code: String, detail: String, findingID: FindingID? = nil, points: Int? = nil) {
        self.code = code
        self.detail = detail
        self.findingID = findingID
        self.points = points
    }

    enum CodingKeys: String, CodingKey {
        case code, detail
        case findingID = "finding_id"
        case points
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
        if let points {
            try container.encode(points, forKey: .points)
        } else {
            try container.encodeNil(forKey: .points)
        }
    }
}

public struct RiskAssessment: Codable, Sendable, Equatable {
    public var verdict: RiskVerdict
    public var mode: RiskMode
    public var score: Int
    public var appetite: Int
    public var reasons: [RiskReason]
    public var safeUnread: Bool?

    public init(
        verdict: RiskVerdict,
        mode: RiskMode,
        score: Int,
        appetite: Int,
        reasons: [RiskReason],
        safeUnread: Bool? = nil
    ) {
        self.verdict = verdict
        self.mode = mode
        self.score = score
        self.appetite = appetite
        self.reasons = reasons
        self.safeUnread = safeUnread
    }

    enum CodingKeys: String, CodingKey {
        case verdict, mode, score, appetite, reasons
        case safeUnread = "safe_unread"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let verdict = try container.decode(RiskVerdict.self, forKey: .verdict)
        let reasons = try container.decode([RiskReason].self, forKey: .reasons)
        let score = try container.decodeIfPresent(Int.self, forKey: .score)
            ?? (verdict == .autoApprove && reasons.isEmpty ? 1 : 5)
        self.init(
            verdict: verdict,
            mode: try container.decode(RiskMode.self, forKey: .mode),
            score: score,
            appetite: try container.decodeIfPresent(Int.self, forKey: .appetite) ?? 1,
            reasons: reasons,
            safeUnread: try container.decodeIfPresent(Bool.self, forKey: .safeUnread)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(verdict, forKey: .verdict)
        try container.encode(mode, forKey: .mode)
        try container.encode(score, forKey: .score)
        try container.encode(appetite, forKey: .appetite)
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
    public var appetite: Int
    public var maxFiles: Int
    public var maxLines: Int
    public var sensitiveGlobs: [String]

    public static let secretGlobs: [String] = [
        "**/.env",
        "**/.env.*",
        "**/*.pem",
        "**/*.key",
        "**/*secret*",
    ]

    public static let v1 = RiskConfig(
        mode: .shadow,
        appetite: 1,
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
        case mode, appetite
        case maxFiles = "max_files"
        case maxLines = "max_lines"
        case sensitiveGlobs = "sensitive_globs"
    }

    public init(
        mode: RiskMode = RiskConfig.v1.mode,
        appetite: Int = RiskConfig.v1.appetite,
        maxFiles: Int = RiskConfig.v1.maxFiles,
        maxLines: Int = RiskConfig.v1.maxLines,
        sensitiveGlobs: [String] = RiskConfig.v1.sensitiveGlobs
    ) {
        self.mode = mode
        self.appetite = min(max(appetite, 1), 5)
        self.maxFiles = max(0, maxFiles)
        self.maxLines = max(0, maxLines)
        self.sensitiveGlobs = sensitiveGlobs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decodeIfPresent(RiskMode.self, forKey: .mode) ?? Self.v1.mode,
            appetite: try container.decodeIfPresent(Int.self, forKey: .appetite) ?? Self.v1.appetite,
            maxFiles: try container.decodeIfPresent(Int.self, forKey: .maxFiles) ?? Self.v1.maxFiles,
            maxLines: try container.decodeIfPresent(Int.self, forKey: .maxLines) ?? Self.v1.maxLines,
            sensitiveGlobs: try container.decodeIfPresent([String].self, forKey: .sensitiveGlobs)
                ?? Self.v1.sensitiveGlobs
        )
    }
}

public enum RiskGate: Sendable {
    public static let maxNegativeWeight = -2
    public static let minRuleWeight = -2
    public static let maxRuleWeight = 3

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
        var hard: [RiskReason] = []
        var scored: [RiskReason] = []

        if input.scope == .incremental {
            hard.append(RiskReason(
                code: "incremental_scope",
                detail: "incremental jobs are not auto-approvable"
            ))
        }
        if input.changeSetSource == .hashInterdiff {
            hard.append(RiskReason(
                code: "degraded_change_set",
                detail: "change-set used hash interdiff, not git history"
            ))
        }
        if !input.reviewersInvoked, !input.files.isEmpty {
            hard.append(RiskReason(
                code: "reviewers_skipped",
                detail: "reviewers did not run on a non-empty change"
            ))
        }
        if input.reviewersInvoked, input.validReviewerFiles < 2 {
            hard.append(RiskReason(
                code: "reviewer_file_missing",
                detail: "\(input.validReviewerFiles) of 2 reviewer files were valid"
            ))
        }
        if input.judgeUnavailable {
            hard.append(RiskReason(
                code: "judge_unavailable",
                detail: "judge container failed or wrote an invalid file"
            ))
        }

        appendSize(
            files: input.files.count,
            lines: input.changedLines,
            maxFiles: input.config.maxFiles,
            maxLines: input.config.maxLines,
            hard: &hard,
            scored: &scored
        )
        appendPaths(files: input.files, operatorGlobs: input.config.sensitiveGlobs, hard: &hard, scored: &scored)
        appendFindings(input.findings, rules: input.rules, hard: &hard, scored: &scored)
        appendWeights(rules: input.rules, files: input.files, hard: &hard, scored: &scored)

        let points = max(scored.compactMap(\.points).reduce(0, +), 0)
        let score = level(fromPoints: points)
        let appetite = input.config.appetite
        let verdict: RiskVerdict
        if !hard.isEmpty || score > appetite {
            verdict = .needsHuman
        } else {
            verdict = .autoApprove
        }
        return RiskAssessment(
            verdict: verdict,
            mode: input.config.mode,
            score: score,
            appetite: appetite,
            reasons: hard + scored
        )
    }

    public static func level(fromPoints points: Int) -> Int {
        switch max(points, 0) {
        case 0: 1
        case 1: 2
        case 2: 3
        case 3, 4: 4
        default: 5
        }
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
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                continue
            }
            if line.hasPrefix("+") || line.hasPrefix("-") {
                count += 1
            }
        }
        return count
    }

    public static func judgeDidNotRun(wroteInput: Bool, outcome: JudgeOutcome) -> Bool {
        !wroteInput || outcome == .containerFailed || outcome == .invalidFile
    }

    public static func encode(_ assessment: RiskAssessment) -> String? {
        guard let data = try? JSONEncoder().encode(assessment) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ raw: String?) -> RiskAssessment? {
        guard let raw, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RiskAssessment.self, from: data)
    }

    private static func appendSize(
        files: Int,
        lines: Int?,
        maxFiles: Int,
        maxLines: Int,
        hard: inout [RiskReason],
        scored: inout [RiskReason]
    ) {
        if maxFiles > 0, files > maxFiles * 4 {
            hard.append(RiskReason(
                code: "too_many_files",
                detail: "\(files) files exceed 4× max_files \(maxFiles)"
            ))
        } else if maxFiles > 0, files > maxFiles {
            scored.append(RiskReason(
                code: "too_many_files",
                detail: "\(files) files exceed max_files \(maxFiles)",
                points: 1
            ))
        }
        if let lines {
            if maxLines > 0, lines > maxLines * 4 {
                hard.append(RiskReason(
                    code: "too_many_lines",
                    detail: "\(lines) changed lines exceed 4× max_lines \(maxLines)"
                ))
            } else if maxLines > 0, lines > maxLines {
                scored.append(RiskReason(
                    code: "too_many_lines",
                    detail: "\(lines) changed lines exceed max_lines \(maxLines)",
                    points: 1
                ))
            }
        } else if files > 0 {
            scored.append(RiskReason(
                code: "unknown_line_count",
                detail: "changed line count is unknown",
                points: 1
            ))
        }
    }

    private static func appendPaths(
        files: [JobFile],
        operatorGlobs: [String],
        hard: inout [RiskReason],
        scored: inout [RiskReason]
    ) {
        let secrets = PathGlob(RiskConfig.secretGlobs)
        let sensitive = PathGlob(operatorGlobs)
        var secretHit = false
        var sensitiveHit = false
        for file in files {
            if matches(secrets, file: file) {
                hard.append(RiskReason(
                    code: "secret_path",
                    detail: "touched \(file.path)"
                ))
                secretHit = true
                break
            }
        }
        if secretHit { return }
        for file in files {
            if matches(sensitive, file: file) {
                scored.append(RiskReason(
                    code: "sensitive_path",
                    detail: "touched \(file.path)",
                    points: 2
                ))
                sensitiveHit = true
                break
            }
        }
        _ = sensitiveHit
    }

    private static func appendFindings(
        _ findings: [Finding],
        rules: [Rule],
        hard: inout [RiskReason],
        scored: inout [RiskReason]
    ) {
        let openAPI = Set(rules.compactMap { rule -> RuleID? in
            if case .openapiBreak = rule.payload { return rule.id }
            return nil
        })
        var warningPoints = 0
        for finding in findings {
            if finding.evidenceOK == false {
                hard.append(RiskReason(
                    code: "unverifiable_finding",
                    detail: "evidence_ok is false",
                    findingID: finding.id
                ))
            }
            if finding.lifecycle == .resolved { continue }
            if finding.judgeVerdict == .drop { continue }
            if finding.judgeVerdict == .unavailable {
                if !hard.contains(where: { $0.code == "judge_unavailable" }) {
                    hard.append(RiskReason(
                        code: "judge_unavailable",
                        detail: "judge_verdict is unavailable",
                        findingID: finding.id
                    ))
                }
                continue
            }
            if let ruleID = finding.ruleID, openAPI.contains(ruleID) {
                hard.append(RiskReason(
                    code: "openapi_break",
                    detail: finding.title,
                    findingID: finding.id
                ))
            }
            let severity = finding.judgeSeverity ?? finding.severity
            switch severity {
            case .error:
                hard.append(RiskReason(
                    code: "kept_error",
                    detail: finding.title,
                    findingID: finding.id
                ))
            case .warning:
                if warningPoints < 3 {
                    scored.append(RiskReason(
                        code: "kept_warning",
                        detail: finding.title,
                        findingID: finding.id,
                        points: 1
                    ))
                    warningPoints += 1
                }
            case .info:
                break
            }
        }
    }

    private static func appendWeights(
        rules: [Rule],
        files: [JobFile],
        hard: inout [RiskReason],
        scored: inout [RiskReason]
    ) {
        var weightDelta = 0
        for rule in rules where rule.enabled && rule.deletedAt == nil {
            guard case .riskWeight(let weight, let match, let veto) = rule.payload else { continue }
            guard fires(match: match, globs: rule.pathGlobs, files: files) else { continue }
            if veto {
                hard.append(RiskReason(
                    code: "weight_veto",
                    detail: rule.title
                ))
                continue
            }
            let clamped = min(max(weight, minRuleWeight), maxRuleWeight)
            scored.append(RiskReason(
                code: "weight_rule",
                detail: rule.title,
                points: clamped
            ))
            weightDelta += clamped
        }
        let negatives = scored.filter { $0.code == "weight_rule" }.compactMap(\.points).filter { $0 < 0 }.reduce(0, +)
        if negatives < maxNegativeWeight {
            let bump = maxNegativeWeight - negatives
            scored.append(RiskReason(
                code: "weight_floor",
                detail: "negative weight rules capped at \(maxNegativeWeight)",
                points: bump
            ))
        }
        _ = weightDelta
    }

    private static func fires(match: RiskWeightMatch, globs: [String], files: [JobFile]) -> Bool {
        let patterns = globs.isEmpty ? ["**/*"] : globs
        if match == .all, isTooBroad(patterns) { return false }
        guard !files.isEmpty else { return false }
        let glob = PathGlob(patterns)
        switch match {
        case .any:
            return files.contains { matches(glob, file: $0) }
        case .all:
            return files.allSatisfy { matches(glob, file: $0) }
        }
    }

    private static func isTooBroad(_ globs: [String]) -> Bool {
        globs.contains { glob in
            let trimmed = glob.trimmingCharacters(in: .whitespaces)
            return trimmed == "**/*" || trimmed == "**" || trimmed == "*"
        }
    }

    private static func matches(_ glob: PathGlob, file: JobFile) -> Bool {
        glob.matches(file.path) || file.oldPath.map { glob.matches($0) } == true
    }
}
