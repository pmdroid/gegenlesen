import Foundation

public struct GitHubReviewReport: Sendable, Equatable, Codable {
    public static let marker = "<!-- gegenlesen-review -->"
    public static let defaultMaxFindings = 10

    public var jobID: String
    public var status: String
    public var headSHA: String?
    public var baseSHA: String?
    public var repository: String?
    public var ledgerURL: String?
    public var risk: RiskSnapshot?
    public var findings: [FindingSnapshot]
    public var omitted: Int
    public var markdown: String

    public struct RiskSnapshot: Sendable, Equatable, Codable {
        public var verdict: String
        public var mode: String
        public var score: Int
        public var appetite: Int
        public var reasons: [ReasonSnapshot]

        public init(
            verdict: String,
            mode: String,
            score: Int,
            appetite: Int,
            reasons: [ReasonSnapshot]
        ) {
            self.verdict = verdict
            self.mode = mode
            self.score = score
            self.appetite = appetite
            self.reasons = reasons
        }

        enum CodingKeys: String, CodingKey {
            case verdict, mode, score, appetite, reasons
        }
    }

    public struct ReasonSnapshot: Sendable, Equatable, Codable {
        public var code: String
        public var detail: String
        public var points: Int?

        public init(code: String, detail: String, points: Int? = nil) {
            self.code = code
            self.detail = detail
            self.points = points
        }
    }

    public struct FindingSnapshot: Sendable, Equatable, Codable {
        public var severity: String
        public var title: String
        public var message: String
        public var filePath: String?
        public var startLine: Int?
        public var endLine: Int?
        public var judgeVerdict: String?
        public var lifecycle: String?

        public init(
            severity: String,
            title: String,
            message: String,
            filePath: String? = nil,
            startLine: Int? = nil,
            endLine: Int? = nil,
            judgeVerdict: String? = nil,
            lifecycle: String? = nil
        ) {
            self.severity = severity
            self.title = title
            self.message = message
            self.filePath = filePath
            self.startLine = startLine
            self.endLine = endLine
            self.judgeVerdict = judgeVerdict
            self.lifecycle = lifecycle
        }

        enum CodingKeys: String, CodingKey {
            case severity, title, message
            case filePath = "file_path"
            case startLine = "start_line"
            case endLine = "end_line"
            case judgeVerdict = "judge_verdict"
            case lifecycle
        }
    }

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case headSHA = "head_sha"
        case baseSHA = "base_sha"
        case repository
        case ledgerURL = "ledger_url"
        case risk, findings, omitted, markdown
    }

    public init(
        jobID: String,
        status: String,
        headSHA: String? = nil,
        baseSHA: String? = nil,
        repository: String? = nil,
        ledgerURL: String? = nil,
        risk: RiskSnapshot? = nil,
        findings: [FindingSnapshot],
        omitted: Int,
        markdown: String
    ) {
        self.jobID = jobID
        self.status = status
        self.headSHA = headSHA
        self.baseSHA = baseSHA
        self.repository = repository
        self.ledgerURL = ledgerURL
        self.risk = risk
        self.findings = findings
        self.omitted = omitted
        self.markdown = markdown
    }

    public static func make(
        jobID: String,
        status: String,
        headSHA: String?,
        baseSHA: String?,
        repository: String?,
        ledgerURL: String?,
        risk: RiskSnapshot?,
        findings: [FindingSnapshot],
        maxFindings: Int = defaultMaxFindings
    ) -> GitHubReviewReport {
        let cap = maxFindings > 0 ? maxFindings : defaultMaxFindings
        let open = findings.filter(isOpen).sorted(by: moreSevere)
        let shown = Array(open.prefix(cap))
        let report = GitHubReviewReport(
            jobID: jobID,
            status: status,
            headSHA: headSHA,
            baseSHA: baseSHA,
            repository: repository,
            ledgerURL: publicLedgerURL(ledgerURL),
            risk: risk,
            findings: shown,
            omitted: max(open.count - shown.count, 0),
            markdown: ""
        )
        return GitHubReviewReport(
            jobID: report.jobID,
            status: report.status,
            headSHA: report.headSHA,
            baseSHA: report.baseSHA,
            repository: report.repository,
            ledgerURL: report.ledgerURL,
            risk: report.risk,
            findings: report.findings,
            omitted: report.omitted,
            markdown: renderMarkdown(report)
        )
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }

    public static func blobURL(
        repository: String?,
        sha: String?,
        path: String?,
        startLine: Int?,
        endLine: Int?
    ) -> String? {
        guard let sha, let path, !path.isEmpty, let repo = githubRepo(repository) else {
            return nil
        }
        var url = "https://\(repo.host)/\(repo.fullName)/blob/\(sha)/\(path)"
        if let startLine {
            url += "#L\(startLine)"
            if let endLine, endLine > startLine {
                url += "-L\(endLine)"
            }
        }
        return url
    }

    public static func githubRepo(_ repository: String?) -> (host: String, fullName: String)? {
        guard var value = repository?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let scheme = value.range(of: "://") {
            value = String(value[scheme.upperBound...])
        }
        if value.hasSuffix(".git") {
            value = String(value.dropLast(4))
        }
        let parts = value.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if parts.count >= 3, parts[0].contains(".") {
            return (parts[0], "\(parts[1])/\(parts[2])")
        }
        if parts.count == 2 {
            return ("github.com", "\(parts[0])/\(parts[1])")
        }
        return nil
    }

    static func isOpen(_ finding: FindingSnapshot) -> Bool {
        if finding.lifecycle == FindingLifecycle.resolved.rawValue { return false }
        if finding.judgeVerdict == JudgeVerdict.drop.rawValue { return false }
        return true
    }

    private static func moreSevere(_ a: FindingSnapshot, _ b: FindingSnapshot) -> Bool {
        let ra = Severity(rawValue: a.severity)?.rank ?? 0
        let rb = Severity(rawValue: b.severity)?.rank ?? 0
        if ra != rb { return ra > rb }
        return (a.filePath ?? "") < (b.filePath ?? "")
    }

    private static func publicLedgerURL(_ raw: String?) -> String? {
        guard let raw, let url = URL(string: raw), let host = url.host else { return nil }
        if host == "127.0.0.1" || host == "localhost" || host == "::1" { return nil }
        return raw
    }

    private static func renderMarkdown(_ report: GitHubReviewReport) -> String {
        var lines: [String] = [marker, ""]
        let verdict = report.risk?.verdict ?? "unknown"
        let score = report.risk.map { "\($0.score)/\($0.appetite)" } ?? "-"
        let mode = report.risk?.mode ?? "-"
        let sha = report.headSHA.map { String($0.prefix(7)) } ?? "-"
        lines.append("## gegenlesen \(verdict)")
        lines.append("")
        lines.append("score \(score) · mode `\(mode)` · `\(sha)` · job `\(report.jobID)`")
        lines.append("")
        if mode == RiskMode.shadow.rawValue || mode == RiskMode.off.rawValue {
            lines.append("Shadow mode. Informational only. The check stays green and gegenlesen does not approve.")
            lines.append("")
        }
        if report.status != "succeeded" {
            lines.append("Job status: `\(report.status)`.")
            lines.append("")
        }
        if report.findings.isEmpty {
            lines.append("No open findings.")
            lines.append("")
        } else {
            lines.append("### Findings")
            lines.append("")
            for finding in report.findings {
                lines.append(findingLine(finding, sha: report.headSHA, repository: report.repository))
                let rationale = oneLine(finding.message)
                if !rationale.isEmpty {
                    lines.append(rationale)
                    lines.append("")
                }
            }
        }
        if report.omitted > 0 {
            if let ledger = report.ledgerURL {
                lines.append("_\(report.omitted) more in [Ledger](\(ledger))._")
            } else {
                lines.append("_\(report.omitted) more findings omitted._")
            }
            lines.append("")
        } else if let ledger = report.ledgerURL {
            lines.append("[Ledger job](\(ledger))")
            lines.append("")
        }
        if let reasons = report.risk?.reasons, !reasons.isEmpty {
            lines.append("### Why this verdict")
            lines.append("")
            for reason in reasons {
                let points = reason.points.map { $0 > 0 ? " +\($0)" : " \($0)" } ?? ""
                lines.append("- `\(reason.code)`\(points)  \(reason.detail)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func findingLine(_ finding: FindingSnapshot, sha: String?, repository: String?) -> String {
        let loc: String
        if let path = finding.filePath, !path.isEmpty {
            var label = path
            if let start = finding.startLine {
                label += ":\(start)"
            }
            if let url = blobURL(
                repository: repository,
                sha: sha,
                path: path,
                startLine: finding.startLine,
                endLine: finding.endLine
            ) {
                loc = "[\(label)](\(url))"
            } else {
                loc = "`\(label)`"
            }
        } else {
            loc = "(no file)"
        }
        return "**\(finding.severity)** \(loc) - \(finding.title)"
    }

    private static func oneLine(_ text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if trimmed.count <= 200 { return String(trimmed) }
        return String(trimmed.prefix(197)) + "..."
    }
}
