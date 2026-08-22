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
    func keptWarningBlocks() {
        var input = baseInput()
        input.findings = [finding(severity: .warning, verdict: .keep)]
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "kept_warning" })
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
        #expect(RiskGate.evaluate(input).reasons.contains { $0.code == "too_many_files" })
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
