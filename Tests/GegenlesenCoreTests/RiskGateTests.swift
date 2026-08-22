import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct RiskGateTests {
    @Test
    func cleanTinyChangeAutoApproves() {
        let report = RiskGate.evaluate(baseInput())
        #expect(report.verdict == .autoApprove)
        #expect(report.reasons.isEmpty)
        #expect(report.mode == .shadow)
    }

    @Test
    func incrementalIsVetoed() {
        var input = baseInput()
        input.scope = .incremental
        let report = RiskGate.evaluate(input)
        #expect(report.verdict == .needsHuman)
        #expect(report.reasons.contains { $0.code == "incremental_scope" })
    }

    @Test
    func hashInterdiffIsVetoed() {
        var input = baseInput()
        input.changeSetSource = .hashInterdiff
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "degraded_change_set" })
    }

    @Test
    func keptWarningBlocksAtAppetiteOne() {
        var input = baseInput()
        input.findings = [finding(severity: .warning, verdict: .keep)]
        let report = RiskGate.evaluate(input)
        #expect(report.reasons.contains { $0.code == "kept_warning" })
        #expect(report.score == 2)
        #expect(report.verdict == .needsHuman)
        input.config.appetite = 2
        #expect(RiskGate.evaluate(input).verdict == .autoApprove)
    }

    @Test
    func droppedFindingDoesNotBlock() {
        var input = baseInput()
        input.findings = [finding(severity: .error, verdict: .drop, evidenceOK: true)]
        #expect(RiskGate.evaluate(input).verdict == .autoApprove)
    }

    @Test
    func unverifiableFindingBlocksEvenIfDropped() {
        var input = baseInput()
        input.findings = [finding(severity: .error, verdict: .drop, evidenceOK: false)]
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "unverifiable_finding" })
    }

    @Test
    func sensitivePathTouchBlocks() {
        var input = baseInput()
        input.files = [
            JobFile(jobID: JobID("11111111-1111-4111-8111-111111111111"), path: "auth/login.swift", status: .modified),
        ]
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "sensitive_path" })
    }

    @Test
    func tooManyFilesBlocks() {
        var input = baseInput()
        input.files = (1...6).map {
            JobFile(
                jobID: JobID("11111111-1111-4111-8111-111111111111"),
                path: "Sources/\($0).swift",
                status: .modified
            )
        }
        let report = RiskGate.evaluate(input)
        #expect(report.reasons.contains { $0.code == "too_many_files" })
        #expect(report.reasons.contains { $0.code == "too_many_files" && $0.points == 1 })
        #expect(report.verdict == .needsHuman)
    }

    @Test
    func fourTimesFileCapIsHard() {
        var input = baseInput()
        input.files = (1...21).map {
            JobFile(
                jobID: JobID("11111111-1111-4111-8111-111111111111"),
                path: "Sources/\($0).swift",
                status: .modified
            )
        }
        let report = RiskGate.evaluate(input)
        #expect(report.reasons.contains { $0.code == "too_many_files" && $0.points == nil })
        #expect(report.verdict == .needsHuman)
        input.config.appetite = 5
        #expect(RiskGate.evaluate(input).verdict == .needsHuman)
    }

    @Test
    func zeroMaxFilesIsFailClosed() {
        var input = baseInput()
        input.config.maxFiles = 0
        input.config.appetite = 5
        let report = RiskGate.evaluate(input)
        #expect(report.reasons.contains { $0.code == "too_many_files" && $0.points == nil })
        #expect(report.verdict == .needsHuman)
    }

    @Test
    func zeroMaxLinesIsFailClosed() {
        var input = baseInput()
        input.changedLines = 1
        input.config.maxLines = 0
        input.config.appetite = 5
        let report = RiskGate.evaluate(input)
        #expect(report.reasons.contains { $0.code == "too_many_lines" && $0.points == nil })
        #expect(report.verdict == .needsHuman)
    }

    @Test
    func unknownLineCountAddsAPoint() {
        var input = baseInput()
        input.changedLines = nil
        let report = RiskGate.evaluate(input)
        #expect(report.reasons.contains { $0.code == "unknown_line_count" && $0.points == 1 })
        #expect(report.score == 2)
        #expect(report.verdict == .needsHuman)
    }

    @Test
    func levelFromPointsBoundaries() {
        #expect(RiskGate.level(fromPoints: 0) == 1)
        #expect(RiskGate.level(fromPoints: 1) == 2)
        #expect(RiskGate.level(fromPoints: 2) == 3)
        #expect(RiskGate.level(fromPoints: 3) == 4)
        #expect(RiskGate.level(fromPoints: 4) == 4)
        #expect(RiskGate.level(fromPoints: 5) == 5)
        #expect(RiskGate.level(fromPoints: 9) == 5)
    }

    @Test
    func missingReviewerFileBlocks() {
        var input = baseInput()
        input.reviewersInvoked = true
        input.validReviewerFiles = 1
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "reviewer_file_missing" })
    }

    @Test
    func skippedReviewersOnNonEmptyChangeBlock() {
        var input = baseInput()
        input.reviewersInvoked = false
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "reviewers_skipped" })
    }

    @Test
    func skippedReviewersOnEmptyChangePass() {
        var input = baseInput()
        input.files = []
        input.reviewersInvoked = false
        #expect(RiskGate.evaluate(input).verdict == .autoApprove)
    }

    @Test
    func judgeUnavailableBlocks() {
        var input = baseInput()
        input.judgeUnavailable = true
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "judge_unavailable" })
    }

    @Test
    func openapiBreakBlocks() {
        var input = baseInput()
        let ruleID = RuleID("openapi-break")
        input.rules = [
            Rule(
                id: ruleID,
                title: "OpenAPI",
                severity: .error,
                kind: .deterministic,
                languages: [],
                pathGlobs: ["**/*.yaml"],
                payload: .openapiBreak(specGlobs: ["**/*.yaml"], failOn: "all", message: "break"),
                createdAt: Date(),
                updatedAt: Date()
            ),
        ]
        input.findings = [finding(severity: .info, verdict: .keep, ruleID: ruleID)]
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "openapi_break" })
    }

    @Test
    func changedLinesCountsDiffHunks() {
        let patch = Data("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,2 +1,3 @@
         keep
        -old
        +new
        +also
        """.utf8)
        #expect(RiskGate.changedLines(in: patch) == 3)
    }

    @Test
    func changedLinesCountsContentThatLooksLikeHeaders() {
        let patch = Data("""
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1 +1,2 @@
        ---- token
        ++++ token
        """.utf8)
        #expect(RiskGate.changedLines(in: patch) == 2)
        let plusPlus = Data("+++ /dev/null\n+--\n+++\n".utf8)
        #expect(RiskGate.changedLines(in: plusPlus) == 2)
    }

    @Test
    func missingJudgeInputIsUnavailable() {
        #expect(RiskGate.judgeDidNotRun(wroteInput: false, outcome: .verdicts(JudgeFile(verdicts: []))))
        #expect(RiskGate.judgeDidNotRun(wroteInput: true, outcome: .containerFailed))
        #expect(RiskGate.judgeDidNotRun(wroteInput: true, outcome: .invalidFile))
        #expect(
            !RiskGate.judgeDidNotRun(
                wroteInput: true,
                outcome: .verdicts(JudgeFile(verdicts: []))
            )
        )
    }

    @Test
    func appetiteOneMatchesEmptySoftSignals() {
        let report = RiskGate.evaluate(baseInput())
        #expect(report.score == 1)
        #expect(report.appetite == 1)
        #expect(report.verdict == .autoApprove)
    }

    @Test
    func weightVetoAlwaysBlocks() {
        var input = baseInput()
        input.files = [
            JobFile(
                jobID: JobID("11111111-1111-4111-8111-111111111111"),
                path: "db/migrations/1.sql",
                status: .added
            ),
        ]
        input.rules = [
            Rule(
                id: RuleID("no-migrations"),
                title: "no migrations",
                severity: .info,
                kind: .deterministic,
                languages: ["*"],
                pathGlobs: ["**/migrations/**"],
                payload: .riskWeight(weight: 3, match: .any, veto: true),
                createdAt: Date(),
                updatedAt: Date()
            ),
        ]
        input.config.appetite = 5
        let report = RiskGate.evaluate(input)
        #expect(report.verdict == .needsHuman)
        #expect(report.reasons.contains { $0.code == "weight_veto" })
    }

    @Test
    func docsOnlyDiscountLowersScore() {
        var input = baseInput()
        input.files = [
            JobFile(
                jobID: JobID("11111111-1111-4111-8111-111111111111"),
                path: "docs/guide.md",
                status: .modified
            ),
        ]
        input.findings = [finding(severity: .warning, verdict: .keep)]
        input.rules = [
            Rule(
                id: RuleID("docs-only"),
                title: "docs only",
                severity: .info,
                kind: .deterministic,
                languages: ["*"],
                pathGlobs: ["docs/**", "**/*.md"],
                payload: .riskWeight(weight: -2, match: .all, veto: false),
                createdAt: Date(),
                updatedAt: Date()
            ),
        ]
        let withDiscount = RiskGate.evaluate(input)
        #expect(withDiscount.score == 1)
        #expect(withDiscount.verdict == .autoApprove)
        input.rules = []
        let without = RiskGate.evaluate(input)
        #expect(without.score == 2)
        #expect(without.verdict == .needsHuman)
    }

    @Test
    func secretPathStaysHard() {
        var input = baseInput()
        input.files = [
            JobFile(
                jobID: JobID("11111111-1111-4111-8111-111111111111"),
                path: ".env",
                status: .modified
            ),
        ]
        input.config.appetite = 5
        let report = RiskGate.evaluate(input)
        #expect(report.verdict == .needsHuman)
        #expect(report.reasons.contains { $0.code == "secret_path" })
    }

    @Test
    func keptErrorStaysHardAtAppetiteFive() {
        var input = baseInput()
        input.findings = [finding(severity: .error, verdict: .keep)]
        input.config.appetite = 5
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "kept_error" })
        #expect(RiskGate.evaluate(input).verdict == .needsHuman)
    }

    @Test
    func negativeWeightsCannotDropBelowFloor() {
        var input = baseInput()
        input.findings = [finding(severity: .warning, verdict: .keep)]
        input.rules = [
            Rule(
                id: RuleID("a"),
                title: "a",
                severity: .info,
                kind: .deterministic,
                languages: ["*"],
                pathGlobs: ["Sources/**"],
                payload: .riskWeight(weight: -2, match: .any, veto: false),
                createdAt: Date(),
                updatedAt: Date()
            ),
            Rule(
                id: RuleID("b"),
                title: "b",
                severity: .info,
                kind: .deterministic,
                languages: ["*"],
                pathGlobs: ["Sources/**"],
                payload: .riskWeight(weight: -2, match: .any, veto: false),
                createdAt: Date(),
                updatedAt: Date()
            ),
        ]
        let report = RiskGate.evaluate(input)
        #expect(report.reasons.contains { $0.code == "weight_floor" })
        let net = report.reasons.compactMap(\.points).reduce(0, +)
        #expect(net >= -1)
    }
}

private func baseInput() -> RiskGate.Input {
    RiskGate.Input(
        scope: .full,
        changeSetSource: .git,
        files: [
            JobFile(
                jobID: JobID("11111111-1111-4111-8111-111111111111"),
                path: "Sources/A.swift",
                status: .modified
            ),
        ],
        findings: [],
        rules: [],
        changedLines: 12,
        reviewersInvoked: true,
        validReviewerFiles: 2,
        judgeUnavailable: false,
        config: .v1
    )
}

private func finding(
    severity: Severity,
    verdict: JudgeVerdict,
    evidenceOK: Bool? = true,
    ruleID: RuleID? = nil
) -> Finding {
    Finding(
        id: FindingID.generate(),
        jobID: JobID("11111111-1111-4111-8111-111111111111"),
        ruleID: ruleID,
        phase: .agent,
        severity: severity,
        title: "finding",
        message: "msg",
        filePath: "Sources/A.swift",
        startLine: 1,
        endLine: 1,
        judgeVerdict: verdict,
        evidenceOK: evidenceOK,
        createdAt: Date()
    )
}
