import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct MineCorpusPipelineTests {
    @Test
    func learnStagesFindingsAndPatch() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let source = sampleJob(
                id: "11111111-1111-4111-8111-111111111111",
                status: .succeeded,
                finishedAt: now
            )
            try await store.insertJob(source)
            try await store.insertFindings(
                [
                    FindingDraft(
                        phase: .agent,
                        severity: .warning,
                        title: "Staged finding title",
                        message: "from the reviewer",
                        filePath: "Sources/A.swift",
                        startLine: 1,
                        endLine: 1,
                        snippet: "print(1)"
                    ),
                ],
                jobID: source.id,
                now: now
            )
            try Data("diff --git a/A.swift b/A.swift\n".utf8).write(
                to: store.blobs.patchURL(jobID: source.id.rawValue)
            )

            let mineID = JobID("22222222-2222-4222-8222-222222222222")
            try await store.insertJob(sampleJob(id: mineID.rawValue, status: .queued))
            try await MineCorpusPipeline(store: store, skipAgent: true, model: "none").run(
                jobID: mineID,
                spec: MineJobSpec(source: .job, sourceJobID: source.id)
            )

            let workspace = store.blobs.workspaceURL(jobID: mineID.rawValue)
            let findings = try String(
                contentsOf: workspace.appendingPathComponent(".gegenlesen/findings.json"),
                encoding: .utf8
            )
            #expect(findings.contains("Staged finding title"))
            #expect(findings.contains("from the reviewer"))
            #expect(
                FileManager.default.fileExists(
                    atPath: workspace.appendingPathComponent("job/change.patch").path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: workspace.appendingPathComponent("job/findings.json").path
                )
            )
        }
    }

    @Test
    func learnStagesMergeIntentOnFeedbackJSON() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            var source = sampleJob(
                id: "11111111-1111-4111-8111-111111111111",
                status: .succeeded,
                finishedAt: now
            )
            source.risk = RiskAssessment(
                verdict: .autoApprove,
                mode: .shadow,
                score: 1,
                appetite: 1,
                reasons: [],
                safeUnread: false
            )
            try await store.insertJob(source)
            try Data("diff --git a/A.swift b/A.swift\n".utf8).write(
                to: store.blobs.patchURL(jobID: source.id.rawValue)
            )

            let mineID = JobID("22222222-2222-4222-8222-222222222222")
            try await store.insertJob(sampleJob(id: mineID.rawValue, status: .queued))
            try await MineCorpusPipeline(store: store, skipAgent: true, model: "none").run(
                jobID: mineID,
                spec: MineJobSpec(source: .job, sourceJobID: source.id)
            )

            let raw = try Data(
                contentsOf: store.blobs.workspaceURL(jobID: mineID.rawValue)
                    .appendingPathComponent("job/feedback.json")
            )
            let object = try #require(
                try JSONSerialization.jsonObject(with: raw) as? [String: Any]
            )
            let intent = try #require(object["merge_intent"] as? [String: Any])
            #expect(intent["would_merge"] as? Bool == false)
            #expect(intent["weight"] as? String == "highest")
            #expect(intent["safe_unread"] as? Bool == false)
        }
    }

    @Test
    func jobLearnInboxesRuleOnlyAfterTwoEndorsements() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            try await endorseAndLearn(
                store: store,
                sourceID: "11111111-1111-4111-8111-111111111111",
                mineID: "22222222-2222-4222-8222-222222222222",
                title: "Silent hop errors",
                now: now
            )
            let afterOne = try await store.listLearnings(status: .pending)
            #expect(!afterOne.contains { $0.kind == .rule })
            #expect(afterOne.contains { $0.kind == .context })

            try await endorseAndLearn(
                store: store,
                sourceID: "33333333-3333-4333-8333-333333333333",
                mineID: "44444444-4444-4444-8444-444444444444",
                title: "silent  hop errors",
                now: now
            )
            let afterTwo = try await store.listLearnings(status: .pending)
            #expect(afterTwo.contains { $0.kind == .rule })
            let rules = try await store.listRules(RuleListFilter(provenance: .suggested))
            #expect(rules.contains { $0.enabled == false })
            #expect(rules.contains { Normalize.titleKey($0.title) == "silent hop errors" })

            var proposed = try #require(afterTwo.first { $0.kind == .rule })
            proposed.status = .dismissed
            proposed.resolvedAt = now
            try await store.updateLearning(proposed)
            try await endorseAndLearn(
                store: store,
                sourceID: "55555555-5555-4555-8555-555555555555",
                mineID: "66666666-6666-4666-8666-666666666666",
                title: "Silent hop errors",
                now: now
            )
            let afterDismiss = try await store.listLearnings(status: .pending, kind: .rule)
            #expect(afterDismiss.isEmpty)

            proposed.clearDismiss()
            proposed.status = .pending
            proposed.resolvedAt = nil
            try await store.updateLearning(proposed)
            let restored = try await store.listLearnings(status: .pending, kind: .rule)
            #expect(restored.contains { $0.id == proposed.id })
        }
    }
}

private func endorseAndLearn(
    store: Store,
    sourceID: String,
    mineID: String,
    title: String,
    now: Date
) async throws {
    let source = sampleJob(id: sourceID, status: .succeeded, finishedAt: now)
    try await store.insertJob(source)
    let inserted = try await store.insertFindings(
        [
            FindingDraft(
                phase: .agent,
                severity: .warning,
                title: title,
                message: "log hop failures",
                filePath: "Sources/A.swift",
                startLine: 1,
                endLine: 1,
                snippet: "hop()"
            ),
        ],
        jobID: source.id,
        now: now
    )
    _ = try await store.applyFindingFeedback(
        finding: inserted[0],
        verdict: .agree,
        reaction: .thumbsUp,
        comment: nil,
        now: now
    )
    try await store.insertJob(sampleJob(id: mineID, status: .queued))
    try await MineCorpusPipeline(store: store, skipAgent: true, model: "none").run(
        jobID: JobID(mineID),
        spec: MineJobSpec(source: .job, sourceJobID: source.id)
    )
}
