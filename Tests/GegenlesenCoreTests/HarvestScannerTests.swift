import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct HarvestScannerTests {
    @Test
    func findsToolConfigsAndProse() throws {
        try withTempDir("harvest-scan") { root in
            try writeFile("README.md", "# barkvisor\nUse the project logger.\n", in: root)
            try writeFile(".swiftlint.yml", "disabled_rules:\n  - line_length\n", in: root)
            try writeFile("Sources/App.swift", "print(1)\n", in: root)
            let scan = HarvestScanner.scan(root: root)
            #expect(scan.prose.contains { $0.path == "README.md" })
            #expect(scan.suppressions.contains { $0.tool == "swiftlint" })
            #expect(!scan.prose.contains { $0.path.contains("App.swift") })
        }
    }
}

@Suite
struct HarvestPipelineTests {
    @Test
    func skipAgentWritesDisabledNotesFromProse() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let tree = dir.appendingPathComponent("tree", isDirectory: true)
            try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
            try writeFile("README.md", "House style: never log secrets.\nSee CONTRIBUTING.\n", in: tree)
            try writeFile("CONTRIBUTING.md", "PRs need tests next to the source file.\n", in: tree)
            try writeFile(".swiftlint.yml", "opt_in_rules:\n  - explicit_acl\n", in: tree)
            let archive = dir.appendingPathComponent("tree.tar.gz")
            try gzipTarCreate(from: tree, to: archive)

            let jobID = JobID("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            try await store.insertJob(sampleJob(id: jobID.rawValue, status: .queued))
            try FileManager.default.createDirectory(
                at: store.blobs.archiveURL(jobID: jobID.rawValue).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: archive,
                to: store.blobs.archiveURL(jobID: jobID.rawValue)
            )

            try await HarvestPipeline(store: store, skipAgent: true, model: "none").run(jobID: jobID)
            let job = try #require(await store.job(id: jobID))
            #expect(job.status == .succeeded)
            let learnings = try await store.listLearnings(status: .pending)
            #expect(learnings.contains { $0.kind == .context && $0.payloadJSON?.contains("harvest") == true })
            let scanURL = store.blobs.workspaceURL(jobID: jobID.rawValue)
                .appendingPathComponent(".gegenlesen/harvest-scan.json")
            #expect(FileManager.default.fileExists(atPath: scanURL.path))
        }
    }

    @Test
    func failedJudgeKeepsCitedMinerDrafts() async throws {
        try await withPackedHarvest { store, jobID in
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: citedHarvestJSON),
                suggestionJudge: FailedSuggestionJudge(),
                model: "none"
            ).run(jobID: jobID)
            let job = try #require(await store.job(id: jobID))
            #expect(job.status == .succeeded)
            let learnings = try await store.listLearnings(status: .pending)
            #expect(learnings.contains { $0.kind == .rule && $0.title.contains("project logger") })
            #expect(learnings.contains { $0.kind == .context && $0.title.contains("CI is optional") })
            let events = try await store.events(jobID: jobID)
            let failed = try #require(events.first { $0.message == "suggestion_judge_failed" })
            #expect(failed.level == .warning)
            #expect(failed.payloadJSON?.contains("\"judged\":false") == true)
            #expect(failed.payloadJSON?.contains("missing_suggestion_judge_file") == true)
            #expect(learnings.contains { $0.payloadJSON?.contains("\"judged\":false") == true })
        }
    }

    @Test
    func successfulDropKeepsNothing() async throws {
        try await withPackedHarvest { store, jobID in
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: citedHarvestJSON),
                suggestionJudge: DroppingSuggestionJudge(),
                model: "none"
            ).run(jobID: jobID)
            let learnings = try await store.listLearnings(status: .pending)
            #expect(!learnings.contains { $0.payloadJSON?.contains("harvest") == true })
            let events = try await store.events(jobID: jobID)
            #expect(events.contains {
                $0.message == "suggestion_judged" && $0.payloadJSON?.contains("\"judged\":true") == true
            })
        }
    }

    @Test
    func ingestExistingHarvestPersistsMinerFile() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let jobID = JobID("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
            try await store.insertJob(sampleJob(id: jobID.rawValue, status: .succeeded))
            let gegenlesen = store.blobs.workspaceURL(jobID: jobID.rawValue)
                .appendingPathComponent(".gegenlesen", isDirectory: true)
            try FileManager.default.createDirectory(at: gegenlesen, withIntermediateDirectories: true)
            try citedHarvestJSON.write(
                to: gegenlesen.appendingPathComponent("harvest.json"),
                atomically: true,
                encoding: .utf8
            )
            let counts = try await HarvestPipeline(store: store, skipAgent: true, model: "none")
                .ingestExistingHarvest(jobID: jobID)
            #expect(counts.rules == 1)
            #expect(counts.notes == 1)
            let learnings = try await store.listLearnings(status: .pending)
            #expect(learnings.count == 2)
        }
    }
}

private let citedHarvestJSON = """
{
  "rules": [{
    "title": "Use the project logger",
    "severity": "warning",
    "kind": "semantic",
    "languages": ["*"],
    "path_globs": ["**/*"],
    "instruction": "Use the project logger.",
    "body": "Use the project logger.",
    "evidence": [{"path": "README.md", "excerpt": "Use the project logger."}]
  }],
  "notes": [{
    "title": "CI is optional",
    "body": "Guest boot is not a required check.",
    "evidence": [{"path": "docs/ci.md", "excerpt": "never a required status check"}]
  }]
}
"""

private struct HarvestMinerStub: MinerRunning {
    var json: String

    func runMiner(
        jobID: JobID,
        workspace: Workspace,
        model: String,
        isCancelled: (@Sendable () async -> Bool)?
    ) async -> MinerRunResult {
        let dir = workspace.root.appendingPathComponent(".gegenlesen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? json.write(to: dir.appendingPathComponent("harvest.json"), atomically: true, encoding: .utf8)
        return MinerRunResult(containerName: "miner", failed: false)
    }
}

private struct FailedSuggestionJudge: SuggestionJudging {
    func runSuggestionJudge(job: Job, workspace: Workspace) async -> SuggestionJudgeRunResult {
        SuggestionJudgeRunResult(
            outcome: .failed,
            containerName: "judge",
            errorMessage: "missing_suggestion_judge_file"
        )
    }
}

private struct DroppingSuggestionJudge: SuggestionJudging {
    func runSuggestionJudge(job: Job, workspace: Workspace) async -> SuggestionJudgeRunResult {
        SuggestionJudgeRunResult(
            outcome: .verdicts([
                SuggestionVerdict(id: "sug_rule_0", verdict: .drop, rationale: "taste"),
                SuggestionVerdict(id: "sug_note_0", verdict: .drop, rationale: "recap"),
            ]),
            containerName: "judge"
        )
    }
}

private func withPackedHarvest(_ body: (Store, JobID) async throws -> Void) async throws {
    try await withTempDataDir { dir in
        let store = try Store.open(dataDir: dir)
        let tree = dir.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try writeFile("README.md", "Use the project logger.\n", in: tree)
        let archive = dir.appendingPathComponent("tree.tar.gz")
        try gzipTarCreate(from: tree, to: archive)
        let jobID = JobID("cccccccc-cccc-4ccc-8ccc-cccccccccccc")
        try await store.insertJob(sampleJob(id: jobID.rawValue, status: .queued))
        try FileManager.default.createDirectory(
            at: store.blobs.archiveURL(jobID: jobID.rawValue).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: archive,
            to: store.blobs.archiveURL(jobID: jobID.rawValue)
        )
        try await body(store, jobID)
    }
}
