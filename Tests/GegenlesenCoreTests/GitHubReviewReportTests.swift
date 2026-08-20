import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct GitHubReviewReportTests {
    @Test
    func markdownIncludesMarkerAndDropsResolvedAndDropped() throws {
        let report = GitHubReviewReport.make(
            jobID: "job-1",
            status: "succeeded",
            headSHA: "abcdef1234567890",
            baseSHA: "0000000",
            repository: "pmdroid/gegenlesen",
            ledgerURL: "http://127.0.0.1:8080/jobs/job-1",
            risk: GitHubReviewReport.RiskSnapshot(
                verdict: "needs_human",
                mode: "shadow",
                score: 2,
                appetite: 1,
                reasons: [
                    GitHubReviewReport.ReasonSnapshot(code: "kept_warning", detail: "logger", points: 1),
                ]
            ),
            findings: [
                GitHubReviewReport.FindingSnapshot(
                    severity: "warning",
                    title: "use the project logger",
                    message: "print() in the hot path\nmore",
                    filePath: "Sources/Foo.swift",
                    startLine: 12,
                    endLine: 14,
                    judgeVerdict: "keep",
                    lifecycle: "new"
                ),
                GitHubReviewReport.FindingSnapshot(
                    severity: "error",
                    title: "dropped",
                    message: "nope",
                    filePath: "Sources/Foo.swift",
                    startLine: 1,
                    judgeVerdict: "drop",
                    lifecycle: "new"
                ),
                GitHubReviewReport.FindingSnapshot(
                    severity: "error",
                    title: "already fixed",
                    message: "gone",
                    filePath: "Sources/Bar.swift",
                    startLine: 3,
                    judgeVerdict: "keep",
                    lifecycle: "resolved"
                ),
            ]
        )
        #expect(report.markdown.contains(GitHubReviewReport.marker))
        #expect(report.markdown.contains("Shadow mode"))
        #expect(report.markdown.contains("use the project logger"))
        #expect(!report.markdown.contains("dropped"))
        #expect(!report.markdown.contains("already fixed"))
        #expect(!report.markdown.contains("127.0.0.1"))
        #expect(report.ledgerURL == nil)
        #expect(report.findings.count == 1)
        #expect(report.markdown.contains("https://github.com/pmdroid/gegenlesen/blob/abcdef1234567890/Sources/Foo.swift#L12-L14"))
        let data = try report.jsonData()
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["job_id"] as? String == "job-1")
        #expect(object?["markdown"] is String)
    }

    @Test
    func capsFindingsAndCountsOmitted() {
        let findings = (1...12).map { index in
            GitHubReviewReport.FindingSnapshot(
                severity: index == 1 ? "error" : "info",
                title: "f\(index)",
                message: "m\(index)",
                filePath: String(format: "a/%02d.swift", index),
                startLine: index,
                judgeVerdict: "keep",
                lifecycle: "new"
            )
        }
        let report = GitHubReviewReport.make(
            jobID: "job-2",
            status: "succeeded",
            headSHA: "deadbeef",
            baseSHA: nil,
            repository: "github.com/acme/app",
            ledgerURL: "https://ledger.example/jobs/job-2",
            risk: GitHubReviewReport.RiskSnapshot(
                verdict: "auto_approve",
                mode: "enforce",
                score: 1,
                appetite: 1,
                reasons: []
            ),
            findings: findings,
            maxFindings: 10
        )
        #expect(report.findings.count == 10)
        #expect(report.omitted == 2)
        #expect(report.findings.first?.title == "f1")
        #expect(report.markdown.contains("2 more in [Ledger](https://ledger.example/jobs/job-2)"))
        #expect(!report.markdown.contains("Shadow mode"))
    }

    @Test
    func githubRepoParsesOriginShapes() {
        let a = GitHubReviewReport.githubRepo("github.com/pmdroid/gegenlesen")
        #expect(a?.host == "github.com")
        #expect(a?.fullName == "pmdroid/gegenlesen")
        let b = GitHubReviewReport.githubRepo("https://github.com/pmdroid/gegenlesen.git")
        #expect(b?.fullName == "pmdroid/gegenlesen")
        let c = GitHubReviewReport.githubRepo("acme/app")
        #expect(c?.host == "github.com")
        #expect(c?.fullName == "acme/app")
    }
}
