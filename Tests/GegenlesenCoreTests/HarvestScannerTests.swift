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
    func failedJudgeQuarantinesAndSkipsInbox() async throws {
        try await withPackedHarvest { store, jobID in
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: citedHarvestJSON),
                suggestionJudge: FailedSuggestionJudge(),
                model: "none"
            ).run(jobID: jobID)
            let job = try #require(await store.job(id: jobID))
            #expect(job.status == .failed)
            #expect(job.errorMessage == "harvest_judge_failed")
            let pending = try await store.listLearnings(status: .pending)
            #expect(!pending.contains { $0.payloadJSON?.contains("harvest") == true })
            let quarantined = try await store.listLearnings(status: .needsRejudge)
            #expect(quarantined.contains { $0.kind == .rule && $0.title.contains("project logger") })
            #expect(quarantined.contains { $0.kind == .context && $0.title.contains("CI is optional") })
            #expect(quarantined.allSatisfy { $0.payloadJSON?.contains("\"judged\":false") == true })
            let events = try await store.events(jobID: jobID)
            let failed = try #require(events.first { $0.message == "suggestion_judge_failed" })
            #expect(failed.level == .warning)
            #expect(failed.payloadJSON?.contains("\"judged\":false") == true)
            #expect(failed.payloadJSON?.contains("missing_suggestion_judge_file") == true)
            #expect(events.contains { $0.message == "harvest_judge_failed" && $0.level == .error })
            #expect(!events.contains { $0.message == "harvest_done" })
            let rules = try await store.listRules(RuleListFilter(includeDeleted: true))
            #expect(!rules.contains { $0.provenance == .harvest })
        }
    }

    @Test
    func minerFailureSkipsInboxAndDoesNotHarvestDone() async throws {
        try await withPackedHarvest { store, jobID in
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: FailedHarvestMiner(),
                suggestionJudge: FailedSuggestionJudge(),
                model: "none"
            ).run(jobID: jobID)
            let job = try #require(await store.job(id: jobID))
            #expect(job.status == .failed)
            #expect(job.errorMessage == "miner_failed")
            let pending = try await store.listLearnings(status: .pending)
            let quarantined = try await store.listLearnings(status: .needsRejudge)
            #expect(pending.isEmpty)
            #expect(quarantined.isEmpty)
            let events = try await store.events(jobID: jobID)
            #expect(events.contains { $0.message == "miner_failed" })
            #expect(!events.contains { $0.message == "harvest_parse_failed" })
            #expect(!events.contains { $0.message == "harvest_done" })
        }
    }

    @Test
    func parseFailureIsNotMinerFailed() async throws {
        try await withPackedHarvest { store, jobID in
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: "{not json"),
                suggestionJudge: KeepingSuggestionJudge(),
                model: "none"
            ).run(jobID: jobID)
            let job = try #require(await store.job(id: jobID))
            #expect(job.status == .failed)
            #expect(job.errorMessage == "harvest_parse_failed")
            let events = try await store.events(jobID: jobID)
            let failed = try #require(events.first { $0.message == "harvest_parse_failed" })
            #expect(failed.level == .error)
            #expect(failed.payloadJSON?.contains("message") == true)
            #expect(!events.contains { $0.message == "miner_failed" })
        }
    }

    @Test
    func highMediumLowHarvestPersistsDisabledRules() async throws {
        try await withPackedHarvest { store, jobID in
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: highMediumLowHarvestJSON),
                suggestionJudge: KeepingSuggestionJudge(),
                model: "none"
            ).run(jobID: jobID)
            let job = try #require(await store.job(id: jobID))
            #expect(job.status == .succeeded)
            let rules = try await store.listRules(RuleListFilter(includeDeleted: true))
            let harvest = rules.filter { $0.provenance == .harvest }
            #expect(harvest.count == 1)
            #expect(harvest[0].enabled == false)
            #expect(harvest[0].severity == .error)
            #expect(harvest[0].title.contains("project logger"))
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

    @Test
    func successfulHarvestClearsLeftoverNeedsRejudge() async throws {
        try await withPackedHarvest { store, firstID in
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: citedHarvestJSON),
                suggestionJudge: FailedSuggestionJudge(),
                model: "none"
            ).run(jobID: firstID)
            try await store.insertLearning(
                Learning(
                    kind: .context,
                    status: .needsRejudge,
                    title: "Stale quarantined draft",
                    body: "from a timed out harvest",
                    payloadJSON: #"{"judged":false,"source":"harvest"}"#
                )
            )
            let secondID = JobID("ffffffff-ffff-4fff-8fff-ffffffffffff")
            try await enqueueHarvestCopy(store: store, from: firstID, to: secondID)
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: citedHarvestJSON),
                suggestionJudge: KeepingSuggestionJudge(),
                model: "none"
            ).run(jobID: secondID)
            let leftover = try await store.listLearnings(status: .needsRejudge)
            #expect(leftover.isEmpty)
            let pending = try await store.listLearnings(status: .pending)
            #expect(pending.contains { $0.title.contains("project logger") })
            #expect(pending.contains { $0.title.contains("CI is optional") })
            #expect(!pending.contains { $0.title == "Stale quarantined draft" })
            let dismissed = try await store.listLearnings(status: .dismissed)
            #expect(dismissed.contains { $0.title == "Stale quarantined draft" })
        }
    }

    @Test
    func dismissedHarvestDoesNotReappear() async throws {
        try await withPackedHarvest { store, firstID in
            let pipeline = HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: citedHarvestJSON),
                suggestionJudge: KeepingSuggestionJudge(),
                model: "none"
            )
            try await pipeline.run(jobID: firstID)
            let pending = try await store.listLearnings(status: .pending)
            #expect(!pending.isEmpty)
            for item in pending {
                var next = item
                next.status = .dismissed
                next.resolvedAt = Date()
                try await store.updateLearning(next)
            }
            let secondID = JobID("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
            try await enqueueHarvestCopy(store: store, from: firstID, to: secondID)
            try await pipeline.run(jobID: secondID)
            let again = try await store.listLearnings(status: .pending)
            #expect(!again.contains { $0.payloadJSON?.contains("harvest") == true })
            let events = try await store.events(jobID: secondID)
            #expect(events.contains { $0.message == "harvest_done" && $0.payloadJSON?.contains("\"skipped\":2") == true })
        }
    }

    @Test
    func acceptedHarvestDoesNotReappear() async throws {
        try await withPackedHarvest { store, firstID in
            let pipeline = HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: citedHarvestJSON),
                suggestionJudge: KeepingSuggestionJudge(),
                model: "none"
            )
            try await pipeline.run(jobID: firstID)
            for item in try await store.listLearnings(status: .pending) {
                var next = item
                next.status = .accepted
                next.resolvedAt = Date()
                try await store.updateLearning(next)
            }
            let secondID = JobID("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
            try await enqueueHarvestCopy(store: store, from: firstID, to: secondID)
            try await pipeline.run(jobID: secondID)
            let again = try await store.listLearnings(status: .pending)
            #expect(!again.contains { $0.payloadJSON?.contains("harvest") == true })
            let loggerRules = try await store.listRules(RuleListFilter(includeDeleted: false))
                .filter { Normalize.titleKey($0.title) == "use the project logger" }
            #expect(loggerRules.count == 1)
        }
    }

    @Test
    func harvestDoesNotInsertTwinOfHandwrittenRule() async throws {
        try await withPackedHarvest { store, jobID in
            let now = Date()
            try await store.insertRule(
                Rule(
                    id: RuleID("use-the-project-logger"),
                    title: "Use the project logger",
                    severity: .warning,
                    kind: .semantic,
                    enabled: true,
                    provenance: .handwritten,
                    languages: ["*"],
                    pathGlobs: ["**/*"],
                    payload: .semantic(instruction: "Use the project logger.", fewShots: []),
                    createdAt: now,
                    updatedAt: now
                )
            )
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: citedHarvestJSON),
                suggestionJudge: KeepingSuggestionJudge(),
                model: "none"
            ).run(jobID: jobID)
            let loggerRules = try await store.listRules(RuleListFilter(includeDeleted: false))
                .filter { Normalize.titleKey($0.title) == "use the project logger" }
            #expect(loggerRules.count == 1)
            #expect(loggerRules[0].id.rawValue == "use-the-project-logger")
            #expect(loggerRules[0].provenance == .handwritten)
        }
    }

    @Test
    func capsNoteBodyAndDropsWholeFileMarkdownDumps() async throws {
        try await withPackedHarvest { store, jobID in
            try await HarvestPipeline(
                store: store,
                skipAgent: false,
                miner: HarvestMinerStub(json: dumpHarvestJSON),
                suggestionJudge: KeepingSuggestionJudge(),
                model: "none"
            ).run(jobID: jobID)
            let job = try #require(await store.job(id: jobID))
            #expect(job.status == .succeeded)
            let pending = try await store.listLearnings(status: .pending)
            #expect(!pending.contains { $0.title.contains("README dump") })
            #expect(!pending.contains { $0.title.contains("Design dump") })
            let kept = try #require(pending.first { $0.title.contains("Logger note") })
            #expect(kept.body.count == HarvestFile.maxNoteBodyChars)
            #expect(!kept.body.contains("TAIL"))
        }
    }
}

@Suite
struct HarvestFileTests {
    @Test
    func mapsHighMediumLowAndDropsUnknownSeverity() throws {
        let data = Data("""
        {
          "rules": [
            {
              "title": "High rule",
              "severity": "high",
              "kind": "semantic",
              "instruction": "Use the project logger.",
              "body": "Use the project logger.",
              "evidence": [{"path": "Sources/Log.swift", "excerpt": "Logger.shared"}]
            },
            {
              "title": "Medium rule",
              "severity": "MEDIUM",
              "kind": "semantic",
              "instruction": "Prefer structured logs.",
              "body": "Prefer structured logs.",
              "evidence": [{"path": "Sources/Log.swift", "excerpt": "os_log"}]
            },
            {
              "title": "Low rule",
              "severity": "low",
              "kind": "semantic",
              "instruction": "Name tests next to sources.",
              "body": "Name tests next to sources.",
              "evidence": [{"path": "Tests/LogTests.swift", "excerpt": "LogTests"}]
            },
            {
              "title": "Unknown rule",
              "severity": "catastrophic",
              "kind": "semantic",
              "instruction": "Do not invent severity.",
              "body": "Do not invent severity.",
              "evidence": [{"path": "Sources/Log.swift", "excerpt": "Logger.shared"}]
            }
          ],
          "notes": []
        }
        """.utf8)
        let bundle = try HarvestFile.parse(data)
        #expect(bundle.rules.count == 4)
        #expect(bundle.rules[0].severity == .error)
        #expect(bundle.rules[1].severity == .warning)
        #expect(bundle.rules[2].severity == .info)
        #expect(bundle.rules[3].severity == .warning)
    }

    @Test
    func rejectsWholeReadmeAndDocsDumps() {
        let readme = HarvestNoteDraft(
            title: "README dump",
            body: String(repeating: "House style. ", count: 80),
            evidence: [RuleExample(path: "README.md", excerpt: String(repeating: "House style. ", count: 80))]
        )
        let design = HarvestNoteDraft(
            title: "Design dump",
            body: String(repeating: "Architecture. ", count: 50),
            evidence: [RuleExample(path: "docs/design.md", excerpt: String(repeating: "Architecture. ", count: 50))]
        )
        let short = HarvestNoteDraft(
            title: "CI is optional",
            body: "Guest boot is not a required check.",
            evidence: [RuleExample(path: "docs/ci.md", excerpt: "never a required status check")]
        )
        #expect(HarvestFile.isWholeFileDump(readme))
        #expect(HarvestFile.isWholeFileDump(design))
        #expect(!HarvestFile.isWholeFileDump(short))
        let original = HarvestNoteDraft(
            title: "Long original",
            body: String(repeating: "Prefer structured logs. ", count: 30),
            evidence: [RuleExample(path: "docs/logging.md", excerpt: "use the project logger")]
        )
        #expect(!HarvestFile.isWholeFileDump(original))
        let capped = HarvestFile.cap(HarvestBundle(notes: [readme, design, short, original]))
        #expect(capped.notes.map(\.title) == ["CI is optional", "Long original"])
    }

    @Test
    func truncatesOversizedNoteBodies() {
        let body = String(repeating: "x", count: HarvestFile.maxNoteBodyChars + 80)
        let note = HarvestNoteDraft(
            title: "Logger note",
            body: body,
            evidence: [RuleExample(path: "Sources/Log.swift", excerpt: "Logger.shared")]
        )
        let capped = HarvestFile.cap(HarvestBundle(notes: [note]))
        #expect(capped.notes.count == 1)
        #expect(capped.notes[0].body.count == HarvestFile.maxNoteBodyChars)
    }
}

private let dumpHarvestJSON: String = {
    let dump = String(repeating: "House style. ", count: 80)
    let long = String(repeating: "x", count: HarvestFile.maxNoteBodyChars) + "TAIL"
    return """
    {
      "rules": [],
      "notes": [
        {"title": "README dump", "body": "\(dump)", "evidence": [{"path": "README.md", "excerpt": "\(dump)"}]},
        {"title": "Design dump", "body": "\(dump)", "evidence": [{"path": "docs/design.md", "excerpt": "\(dump)"}]},
        {"title": "Logger note", "body": "\(long)", "evidence": [{"path": "Sources/Log.swift", "excerpt": "Logger.shared"}]}
      ]
    }
    """
}()

private let highMediumLowHarvestJSON = """
{
  "rules": [{
    "title": "Use the project logger",
    "severity": "high",
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
        engine: String,
        model: String,
        isCancelled: (@Sendable () async -> Bool)?
    ) async -> MinerRunResult {
        let dir = workspace.root.appendingPathComponent(".gegenlesen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? json.write(to: dir.appendingPathComponent("harvest.json"), atomically: true, encoding: .utf8)
        return MinerRunResult(containerName: "miner", failed: false)
    }
}

private struct FailedHarvestMiner: MinerRunning {
    func runMiner(
        jobID: JobID,
        workspace: Workspace,
        engine: String,
        model: String,
        isCancelled: (@Sendable () async -> Bool)?
    ) async -> MinerRunResult {
        MinerRunResult(containerName: "miner", failed: true, errorMessage: "miner_failed")
    }
}

private struct KeepingSuggestionJudge: SuggestionJudging {
    func runSuggestionJudge(job: Job, workspace: Workspace) async -> SuggestionJudgeRunResult {
        SuggestionJudgeRunResult(
            outcome: .verdicts([
                SuggestionVerdict(id: "sug_rule_0", verdict: .keep, rationale: "convention"),
                SuggestionVerdict(id: "sug_note_0", verdict: .keep, rationale: "durable"),
            ]),
            containerName: "judge"
        )
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

private func enqueueHarvestCopy(store: Store, from: JobID, to: JobID) async throws {
    try await store.insertJob(sampleJob(id: to.rawValue, status: .queued))
    let dest = store.blobs.archiveURL(jobID: to.rawValue)
    try FileManager.default.createDirectory(
        at: dest.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(at: store.blobs.archiveURL(jobID: from.rawValue), to: dest)
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
