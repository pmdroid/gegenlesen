import Foundation
import Testing
@testable import MeisterCore

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
    func emptyDropRationaleKeeps() {
        let finding = sampleFinding(evidenceOK: true)
        let merged = JudgeMerge.merge(
            candidates: [finding],
            judge: .verdicts(
                JudgeFile(verdicts: [
                    JudgeVerdictRow(findingID: finding.id, verdict: .drop, rationale: "   "),
                ])
            )
        )
        #expect(merged[0].judgeVerdict == .keep)
        #expect(merged[0].judgeRationale == "host: empty drop rationale ignored")
    }

    @Test
    func missingIdDefaultsToKeep() {
        let finding = sampleFinding(evidenceOK: true)
        let merged = JudgeMerge.merge(
            candidates: [finding],
            judge: .verdicts(JudgeFile(verdicts: []))
        )
        #expect(merged[0].judgeVerdict == .keep)
        #expect(merged[0].judgeRationale == "judge omitted id; default keep")
    }

    @Test
    func unavailableOnJudgeFail() {
        let finding = sampleFinding(evidenceOK: true)
        for outcome: JudgeOutcome in [.containerFailed, .invalidFile] {
            let merged = JudgeMerge.merge(candidates: [finding], judge: outcome)
            #expect(merged[0].judgeVerdict == .unavailable)
            #expect(merged[0].judgeRationale == "judge unavailable; default keep")
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
        #expect(same[0].judgeVerdict == .keep)
        #expect(same[0].judgeRationale == "host: downgrade not strictly lower; kept")
    }

    @Test
    func unknownFindingIdIsIgnored() {
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
        #expect(merged[0].judgeVerdict == .keep)
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
    func parseRejectsExtraKeysAndAcceptsEmptyRationale() {
        let invalid = Data(#"{"verdicts":[],"extra":true}"#.utf8)
        #expect(JudgeMerge.parse(invalid) == .invalidFile)

        let empty = Data(#"{"verdicts":[{"finding_id":"fnd_1","verdict":"drop","rationale":""}]}"#.utf8)
        guard case .verdicts(let file) = JudgeMerge.parse(empty) else {
            Issue.record("expected verdicts")
            return
        }
        #expect(file.verdicts.count == 1)
        #expect(file.verdicts[0].rationale.isEmpty)
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
            let dest = workspace.root.appendingPathComponent(".meister/judge-input.json")
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
