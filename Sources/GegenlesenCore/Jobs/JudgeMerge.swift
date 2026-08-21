import Foundation

public enum JudgeDecision: String, Codable, Sendable, Equatable {
    case keep, drop, downgrade

    public static func parse(_ raw: String) -> JudgeDecision? {
        JudgeDecision(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}

public struct JudgeFile: Sendable, Equatable {
    public var verdicts: [JudgeVerdictRow]

    public init(verdicts: [JudgeVerdictRow]) {
        self.verdicts = verdicts
    }
}

public struct JudgeVerdictRow: Sendable, Equatable {
    public var findingID: FindingID
    public var verdict: JudgeDecision
    public var rationale: String
    public var severity: Severity?

    public init(
        findingID: FindingID,
        verdict: JudgeDecision,
        rationale: String,
        severity: Severity? = nil
    ) {
        self.findingID = findingID
        self.verdict = verdict
        self.rationale = rationale
        self.severity = severity
    }
}

public struct JudgeInputFile: Codable, Sendable, Equatable {
    public var candidates: [JudgeCandidate]

    public init(candidates: [JudgeCandidate]) {
        self.candidates = candidates
    }
}

public struct JudgeCandidate: Codable, Sendable, Equatable {
    public var id: FindingID
    public var ruleID: RuleID?
    public var severity: Severity
    public var title: String
    public var message: String
    public var filePath: String
    public var startLine: Int
    public var endLine: Int
    public var snippet: String
    public var rationale: String?
    public var phase: FindingPhase
    public var evidenceOK: Bool
    public var actualSlice: String

    public init(
        id: FindingID,
        ruleID: RuleID? = nil,
        severity: Severity,
        title: String,
        message: String,
        filePath: String,
        startLine: Int,
        endLine: Int,
        snippet: String,
        rationale: String? = nil,
        phase: FindingPhase,
        evidenceOK: Bool,
        actualSlice: String
    ) {
        self.id = id
        self.ruleID = ruleID
        self.severity = severity
        self.title = title
        self.message = message
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.snippet = snippet
        self.rationale = rationale
        self.phase = phase
        self.evidenceOK = evidenceOK
        self.actualSlice = actualSlice
    }

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

public enum JudgeOutcome: Sendable, Equatable {
    case verdicts(JudgeFile)
    case containerFailed
    case invalidFile
}

public enum JudgeMerge: Sendable {
    public static func shouldJudge(_ finding: Finding, commandRuleIDs: Set<RuleID>) -> Bool {
        switch finding.lifecycle {
        case .stillOpen, .relocated, .resolved:
            return false
        case .new:
            break
        }
        switch finding.phase {
        case .agent:
            return true
        case .deterministic:
            guard let ruleID = finding.ruleID else { return false }
            if commandRuleIDs.contains(ruleID) { return true }
            let raw = ruleID.rawValue
            if raw == "scanner-gitleaks" || raw == "scanner-osv-scanner" {
                return false
            }
            return raw.hasPrefix("scanner-")
        }
    }

    public static func commandRuleIDs(from rules: [Rule]) -> Set<RuleID> {
        Set(rules.compactMap { rule in
            if case .command = rule.payload { return rule.id }
            return nil
        })
    }

    public static func nextLower(_ severity: Severity) -> Severity? {
        switch severity {
        case .error: .warning
        case .warning: .info
        case .info: nil
        }
    }

    public static func merge(candidates: [Finding], judge: JudgeOutcome) -> [Finding] {
        switch judge {
        case .containerFailed, .invalidFile:
            return candidates.map { finding in
                var next = finding
                next.judgeVerdict = .unavailable
                next.judgeSeverity = finding.severity
                next.judgeRationale = "judge unavailable; default keep"
                return next
            }
        case .verdicts(let file):
            return merge(candidates: candidates, file: file)
        }
    }

    public static func parse(_ data: Data) -> JudgeOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalidFile
        }
        let allowedRoot: Set<String> = ["verdicts"]
        if !Set(root.keys).isSubset(of: allowedRoot) {
            return .invalidFile
        }
        guard let raw = root["verdicts"] as? [Any] else {
            return .invalidFile
        }
        var rows: [JudgeVerdictRow] = []
        rows.reserveCapacity(min(raw.count, 200))
        let allowedRow: Set<String> = ["finding_id", "verdict", "rationale", "severity"]
        for item in raw.prefix(200) {
            guard let object = item as? [String: Any] else {
                return .invalidFile
            }
            if !Set(object.keys).isSubset(of: allowedRow) {
                return .invalidFile
            }
            guard let id = object["finding_id"] as? String, !id.isEmpty,
                  let verdictRaw = object["verdict"] as? String,
                  let verdict = JudgeDecision.parse(verdictRaw),
                  let rationale = object["rationale"] as? String
            else {
                return .invalidFile
            }
            let severity: Severity?
            if let rawSeverity = object["severity"] {
                guard let text = rawSeverity as? String, let parsed = Severity(rawValue: text) else {
                    return .invalidFile
                }
                severity = parsed
            } else {
                severity = nil
            }
            rows.append(
                JudgeVerdictRow(
                    findingID: FindingID(id),
                    verdict: verdict,
                    rationale: rationale,
                    severity: severity
                )
            )
        }
        return .verdicts(JudgeFile(verdicts: rows))
    }

    private static func merge(candidates: [Finding], file: JudgeFile) -> [Finding] {
        var byID: [String: JudgeVerdictRow] = [:]
        for row in file.verdicts {
            byID[row.findingID.rawValue] = row
        }

        return candidates.map { candidate in
            var next = candidate
            if candidate.evidenceOK == false {
                next.judgeVerdict = .drop
                next.judgeSeverity = candidate.severity
                next.judgeRationale = "host: snippet not present at file:lines"
                return next
            }

            guard let row = byID[candidate.id.rawValue] else {
                next.judgeVerdict = .keep
                next.judgeSeverity = candidate.severity
                next.judgeRationale = "judge omitted id; default keep"
                return next
            }

            switch row.verdict {
            case .keep:
                next.judgeVerdict = .keep
                next.judgeSeverity = candidate.severity
                next.judgeRationale = row.rationale
            case .drop:
                if !row.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    next.judgeVerdict = .drop
                    next.judgeSeverity = candidate.severity
                    next.judgeRationale = row.rationale
                } else {
                    next.judgeVerdict = .keep
                    next.judgeSeverity = candidate.severity
                    next.judgeRationale = "host: empty drop rationale ignored"
                }
            case .downgrade:
                let newSev = row.severity ?? nextLower(candidate.severity)
                if let newSev, newSev.rank < candidate.severity.rank {
                    next.judgeVerdict = .downgrade
                    next.judgeSeverity = newSev
                    next.judgeRationale = row.rationale
                } else {
                    next.judgeVerdict = .keep
                    next.judgeSeverity = candidate.severity
                    next.judgeRationale = "host: downgrade not strictly lower; kept"
                }
            }
            return next
        }
    }
}
