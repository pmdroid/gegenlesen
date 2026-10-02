import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct JudgeMergeTests {
    @Test
    func hostForcesDropWhenEvidenceNotOk() {
        let finding = sampleFinding(evidenceOK: false)
        let merged = JudgeMerge.merge(
            candidates: [finding],
            judge: .verdicts(
                JudgeFile(verdicts: [
                    JudgeVerdictRow(
                        findingID: finding.id,
                        verdict: .keep,
                        rationale: "looks fine"
                    ),
                ])
            )
        )
        #expect(merged.count == 1)
        #expect(merged[0].judgeVerdict == .drop)
        #expect(merged[0].judgeRationale == "host: snippet not present at file:lines")
        #expect(merged[0].judgeSeverity == finding.severity)
    }

    @Test
    func emptyDropRationaleIsUnavailable() {
        let finding = sampleFinding(evidenceOK: true)
        let merged = JudgeMerge.merge(
            candidates: [finding],
            judge: .verdicts(
                JudgeFile(verdicts: [
                    JudgeVerdictRow(findingID: finding.id, verdict: .drop, rationale: "   "),
                ])
            )
        )
        #expect(merged[0].judgeVerdict == .unavailable)
        #expect(merged[0].judgeRationale == "judge returned an invalid verdict; verification incomplete")
    }

    @Test
    func missingIdIsUnavailable() {
        let finding = sampleFinding(evidenceOK: true)
        let merged = JudgeMerge.merge(
            candidates: [finding],
            judge: .verdicts(JudgeFile(verdicts: []))
        )
        #expect(merged[0].judgeVerdict == .unavailable)
        #expect(merged[0].judgeRationale == "judge omitted finding; verification incomplete")
    }

    @Test
    func unavailableOnJudgeFail() {
        let finding = sampleFinding(evidenceOK: true)
        for outcome: JudgeOutcome in [.containerFailed, .invalidFile] {
            let merged = JudgeMerge.merge(candidates: [finding], judge: outcome)
            #expect(merged[0].judgeVerdict == .unavailable)
            #expect(merged[0].judgeRationale == "judge unavailable; verification incomplete")
        }
    }

    @Test
    func downgradeOnlyIfStrictlyLower() {
        let finding = sampleFinding(severity: .error, evidenceOK: true)
        let down = JudgeMerge.merge(
            candidates: [finding],
            judge: .verdicts(
                JudgeFile(verdicts: [
                    JudgeVerdictRow(
                        findingID: finding.id,
                        verdict: .downgrade,
                        rationale: "overstated",
                        severity: .warning
                    ),
                ])
            )
        )
        #expect(down[0].judgeVerdict == .downgrade)
        #expect(down[0].judgeSeverity == .warning)

        let same = JudgeMerge.merge(
            candidates: [finding],
            judge: .verdicts(
                JudgeFile(verdicts: [
                    JudgeVerdictRow(
                        findingID: finding.id,
                        verdict: .downgrade,
                        rationale: "nope",
                        severity: .error
                    ),
                ])
            )
        )
        #expect(same[0].judgeVerdict == .unavailable)
        #expect(same[0].judgeRationale == "judge returned an invalid verdict; verification incomplete")
    }

    @Test
    func unknownFindingIdInvalidatesVerdicts() {
        let finding = sampleFinding(evidenceOK: true)
        let extra = FindingID.generate()
        let merged = JudgeMerge.merge(
            candidates: [finding],
            judge: .verdicts(
                JudgeFile(verdicts: [
                    JudgeVerdictRow(findingID: extra, verdict: .drop, rationale: "invented"),
                ])
            )
        )
        #expect(merged.count == 1)
        #expect(merged[0].id == finding.id)
        #expect(merged[0].judgeVerdict == .unavailable)
    }

    @Test
    func mechanicalCheckersAreNotJudged() {
        let regex = sampleFinding(phase: .deterministic, ruleID: RuleID("no-secrets"), evidenceOK: nil)
        let command = sampleFinding(phase: .deterministic, ruleID: RuleID("custom-cmd"), evidenceOK: nil)
        let agent = sampleFinding(phase: .agent, evidenceOK: true)
        let commandIDs: Set<RuleID> = [RuleID("custom-cmd")]
        #expect(JudgeMerge.shouldJudge(regex, commandRuleIDs: commandIDs) == false)
        #expect(JudgeMerge.shouldJudge(command, commandRuleIDs: commandIDs) == true)
        #expect(JudgeMerge.shouldJudge(agent, commandRuleIDs: commandIDs) == true)
        let gitleaks = sampleFinding(phase: .deterministic, ruleID: RuleID("scanner-gitleaks"), evidenceOK: nil)
        let osv = sampleFinding(phase: .deterministic, ruleID: RuleID("scanner-osv-scanner"), evidenceOK: nil)
        let custom = sampleFinding(phase: .deterministic, ruleID: RuleID("scanner-check-shell"), evidenceOK: nil)
        #expect(JudgeMerge.shouldJudge(gitleaks, commandRuleIDs: commandIDs) == false)
        #expect(JudgeMerge.shouldJudge(osv, commandRuleIDs: commandIDs) == false)
        #expect(JudgeMerge.shouldJudge(custom, commandRuleIDs: commandIDs) == true)
    }

    @Test
    func droppedSummaryCountsDropOnly() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let job = Job(
                id: JobID.generate(),
                createdAt: now,
                updatedAt: now,
                status: .succeeded,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j"
            )
            try await store.insertJob(job)
            let drop = sampleFinding(jobID: job.id, evidenceOK: true)
            var dropPersisted = drop
            dropPersisted.judgeVerdict = .drop
            var unavailable = sampleFinding(jobID: job.id, evidenceOK: true)
            unavailable.judgeVerdict = .unavailable
            var keep = sampleFinding(jobID: job.id, evidenceOK: true)
            keep.judgeVerdict = .keep
            try await store.insertParsedFindings([dropPersisted, unavailable, keep])
            let summary = try await store.summary(jobID: job.id)
            #expect(summary.dropped == 1)
            #expect(summary.new == 3)
        }
    }

    @Test
    func parseRejectsInvalidRows() {
        let invalid = [
            #"{"verdicts":[],"extra":true}"#,
            #"{"verdicts":[{"finding_id":"fnd_1","verdict":"drop","rationale":""}]}"#,
            #"{"verdicts":[{"finding_id":"fnd_1","verdict":"keep","rationale":"  "}]}"#,
            #"{"verdicts":[{"finding_id":" ","verdict":"keep","rationale":"verified"}]}"#,
            #"{"verdicts":[{"finding_id":"fnd_1","verdict":"keep","rationale":"yes"},{"finding_id":"fnd_1","verdict":"drop","rationale":"no"}]}"#,
        ]
        for json in invalid {
            #expect(JudgeMerge.parse(Data(json.utf8)) == .invalidFile)
        }
    }

    @Test
    func judgeCanExplicitlyReportUnverifiedEvidence() throws {
        let finding = sampleFinding(evidenceOK: true)
        let data = try JSONSerialization.data(withJSONObject: ["verdicts": [[
            "finding_id": finding.id.rawValue, "verdict": "unverified", "rationale": "Caller contract could not be established",
        ]]])
        let merged = JudgeMerge.merge(candidates: [finding], judge: JudgeMerge.parse(data))
        #expect(merged[0].judgeVerdict == .unavailable)
        #expect(merged[0].judgeRationale == "Caller contract could not be established")
    }

    @Test
    func duplicateVerdictsAreUnavailable() {
        let finding = sampleFinding(evidenceOK: true)
        let merged = JudgeMerge.merge(
            candidates: [finding],
            judge: .verdicts(JudgeFile(verdicts: [
                JudgeVerdictRow(findingID: finding.id, verdict: .keep, rationale: "yes"),
                JudgeVerdictRow(findingID: finding.id, verdict: .drop, rationale: "no"),
            ]))
        )
        #expect(merged[0].judgeVerdict == .unavailable)
    }

    @Test
    func invalidEvidenceDropsEvenWhenJudgeFails() {
        let finding = sampleFinding(evidenceOK: false)
        for outcome: JudgeOutcome in [.containerFailed, .invalidFile] {
            let merged = JudgeMerge.merge(candidates: [finding], judge: outcome)
            #expect(merged[0].judgeVerdict == .drop)
            #expect(merged[0].judgeRationale == "host: snippet not present at file:lines")
        }
    }

    @Test
    func handoffAndParserPreserveEveryCandidate() throws {
        try withTempDir("handoff-complete") { root in
            let findings = (0..<201).map { _ in sampleFinding(evidenceOK: true) }
            let input = JudgeHandoff.inputFile(from: findings, workspace: Workspace(root: root))
            #expect(input.candidates.count == findings.count)
            let rows = findings.map { ["finding_id": $0.id.rawValue, "verdict": "keep", "rationale": "verified"] }
            let data = try JSONSerialization.data(withJSONObject: ["verdicts": rows])
            guard case .verdicts(let file) = JudgeMerge.parse(data) else {
                Issue.record("expected all verdicts")
                return
            }
            #expect(file.verdicts.count == findings.count)
            let merged = JudgeMerge.merge(candidates: findings, judge: .verdicts(file))
            #expect(merged.allSatisfy { $0.judgeVerdict == .keep })
        }
    }

    @Test
    func parseAcceptsUppercaseVerdict() {
        let data = Data(#"{"verdicts":[{"finding_id":"fnd_1","verdict":"KEEP","rationale":"saw it in source"}]}"#.utf8)
        guard case .verdicts(let file) = JudgeMerge.parse(data) else {
            Issue.record("expected verdicts")
            return
        }
        #expect(file.verdicts[0].verdict == .keep)
    }

    @Test
    func handoffWritesJudgeInputAndBlobs() throws {
        try withTempDir("handoff") { root in
            try writeFile("Sources/A.swift", "print(2)\n", in: root)
            let workspace = Workspace(root: root)
            let blobs = BlobStore(root: root.appendingPathComponent("var"))
            try blobs.ensureLayout()
            let jobID = JobID.generate()
            let finding = sampleFinding(
                jobID: jobID,
                snippet: "print(2)",
                evidenceOK: nil
            )
            let prepared = JudgeHandoff.prepareCandidates(
                [finding],
                commandRuleIDs: [],
                workspace: workspace
            )
            #expect(prepared[0].evidenceOK == true)
            let input = JudgeHandoff.inputFile(from: prepared, workspace: workspace)
            try JudgeHandoff.writeInput(input, workspace: workspace, blobs: blobs, jobID: jobID)
            let dest = workspace.root.appendingPathComponent(".gegenlesen/judge-input.json")
            #expect(FileManager.default.fileExists(atPath: dest.path))
            let pre = blobs.findingsURL(jobID: jobID.rawValue, stage: "pre-judge")
            #expect(FileManager.default.fileExists(atPath: pre.path))
            let decoded = try JSONDecoder().decode(JudgeInputFile.self, from: Data(contentsOf: dest))
            #expect(decoded.candidates.count == 1)
            #expect(decoded.candidates[0].id == finding.id)
            #expect(decoded.candidates[0].evidenceOK == true)
            #expect(decoded.candidates[0].actualSlice.contains("print(2)"))
        }
    }
}

private func sampleFinding(
    jobID: JobID = JobID.generate(),
    phase: FindingPhase = .agent,
    ruleID: RuleID? = nil,
    severity: Severity = .error,
    snippet: String = "let x = 1",
    evidenceOK: Bool?
) -> Finding {
    Finding(
        id: FindingID.generate(),
        jobID: jobID,
        ruleID: ruleID,
        phase: phase,
        reviewerSlot: phase == .agent ? .modelA : nil,
        severity: severity,
        title: "title",
        message: "message",
        filePath: "Sources/A.swift",
        startLine: 1,
        endLine: 1,
        snippet: snippet,
        evidenceOK: evidenceOK,
        createdAt: Date()
    )
}
