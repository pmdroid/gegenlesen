import Foundation
import Testing
@testable import MeisterCore

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
                contentsOf: workspace.appendingPathComponent(".meister/findings.json"),
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
}
