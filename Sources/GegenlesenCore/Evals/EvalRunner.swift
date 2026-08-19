import Foundation

public struct EvalCaseReport: Sendable, Equatable {
    public var id: String
    public var status: Status
    public var detail: String
    public var recallHits: Int
    public var twinHits: Int

    public enum Status: String, Sendable, Equatable {
        case pass
        case fail
        case skip
    }
}

public struct EvalReport: Sendable, Equatable {
    public var cases: [EvalCaseReport]

    public var passed: Int { cases.filter { $0.status == .pass }.count }
    public var failed: Int { cases.filter { $0.status == .fail }.count }
    public var skipped: Int { cases.filter { $0.status == .skip }.count }

    public func render() -> String {
        var lines: [String] = []
        for item in cases {
            switch item.status {
            case .pass:
                lines.append("PASS  \(item.id)  \(item.detail)")
            case .fail:
                lines.append("FAIL  \(item.id)  \(item.detail)")
            case .skip:
                lines.append("SKIP  \(item.id)  \(item.detail)")
            }
        }
        lines.append("\(passed) passed, \(failed) failed, \(skipped) skipped")
        return lines.joined(separator: "\n")
    }
}

public struct EvalRunner: Sendable {
    public var repoRoot: URL
    public var deterministic: any DeterministicRunning
    public var rulesDirectory: URL

    public init(repoRoot: URL, deterministic: any DeterministicRunning, rulesDirectory: URL? = nil) {
        self.repoRoot = repoRoot
        self.deterministic = deterministic
        self.rulesDirectory = rulesDirectory ?? repoRoot.appendingPathComponent("rules", isDirectory: true)
    }

    public func run() async throws -> EvalReport {
        let cases = try EvalCorpus.load(casesRoot: repoRoot.appendingPathComponent("evals/cases"))
        var reports: [EvalCaseReport] = []
        for evalCase in cases {
            if !evalCase.ci {
                reports.append(
                    EvalCaseReport(
                        id: evalCase.id,
                        status: .skip,
                        detail: evalCase.skipReason ?? "ci: false",
                        recallHits: 0,
                        twinHits: 0
                    )
                )
                continue
            }
            if evalCase.layer == .agent {
                reports.append(
                    EvalCaseReport(
                        id: evalCase.id,
                        status: .skip,
                        detail: evalCase.skipReason ?? "agent layer; live nightly only",
                        recallHits: 0,
                        twinHits: 0
                    )
                )
                continue
            }
            reports.append(try await runCase(evalCase))
        }
        return EvalReport(cases: reports)
    }

    private func runCase(_ evalCase: EvalCase) async throws -> EvalCaseReport {
        let packScript = repoRoot.appendingPathComponent("scripts/pack-repo.sh")
        let base = FileManager.default.fileExists(atPath: evalCase.baseDirectory.path)
            ? evalCase.baseDirectory
            : nil
        do {
            let archive = try EvalPacker.pack(head: evalCase.headDirectory, base: base, packScript: packScript)
            defer { try? FileManager.default.removeItem(at: archive) }
            let findings = try await review(archive: archive)
            let candidates = findings
                .filter { matchesLayer($0.phase, layer: evalCase.layer) }
                .map(GoldCandidate.init)
            let scored = score(candidates: candidates, gold: evalCase)
            if evalCase.hasTwin {
                let twinArchive = try EvalPacker.pack(
                    head: evalCase.twinDirectory,
                    base: base,
                    packScript: packScript
                )
                defer { try? FileManager.default.removeItem(at: twinArchive) }
                let twinFindings = try await review(archive: twinArchive)
                let twinCandidates = twinFindings
                    .filter { matchesLayer($0.phase, layer: evalCase.layer) }
                    .map(GoldCandidate.init)
                let twinHits = GoldMatch.ruleHits(candidates: twinCandidates, ruleID: evalCase.ruleID)
                if !twinHits.isEmpty {
                    return EvalCaseReport(
                        id: evalCase.id,
                        status: .fail,
                        detail: "twin fired \(twinHits.count) \(evalCase.ruleID) finding(s)",
                        recallHits: scored.hits,
                        twinHits: twinHits.count
                    )
                }
                if scored.pass {
                    return EvalCaseReport(
                        id: evalCase.id,
                        status: .pass,
                        detail: "recall=\(scored.hits) twin=0",
                        recallHits: scored.hits,
                        twinHits: 0
                    )
                }
                return EvalCaseReport(
                    id: evalCase.id,
                    status: .fail,
                    detail: scored.detail,
                    recallHits: scored.hits,
                    twinHits: 0
                )
            }
            return EvalCaseReport(
                id: evalCase.id,
                status: scored.pass ? .pass : .fail,
                detail: scored.detail,
                recallHits: scored.hits,
                twinHits: 0
            )
        } catch {
            return EvalCaseReport(
                id: evalCase.id,
                status: .fail,
                detail: String(describing: error),
                recallHits: 0,
                twinHits: 0
            )
        }
    }

    private func score(candidates: [GoldCandidate], gold: EvalCase) -> (pass: Bool, hits: Int, detail: String) {
        if gold.mustFind {
            let hits = GoldMatch.hits(candidates: candidates, gold: gold)
            if hits.isEmpty {
                let sameRule = GoldMatch.ruleHits(candidates: candidates, ruleID: gold.ruleID)
                let extra = sameRule.isEmpty
                    ? "no \(gold.ruleID) finding"
                    : "\(gold.ruleID) found but path/lines missed"
                return (false, 0, extra)
            }
            return (true, hits.count, "recall=\(hits.count)")
        }
        let hits = GoldMatch.ruleHits(candidates: candidates, ruleID: gold.ruleID)
        if hits.isEmpty {
            return (true, 0, "\(gold.ruleID) did not fire")
        }
        return (false, hits.count, "unexpected \(hits.count) \(gold.ruleID) finding(s)")
    }

    private func matchesLayer(_ phase: FindingPhase, layer: EvalLayer) -> Bool {
        switch layer {
        case .either: true
        case .rules: phase == .deterministic
        case .agent: phase == .agent
        }
    }

    private func review(archive: URL) async throws -> [Finding] {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            _ = try await RuleSeeder.upsertAbsent(from: rulesDirectory, into: store)
            let job = queuedEvalJob()
            try await store.insertJob(job)
            try FileManager.default.copyItem(
                at: archive,
                to: store.blobs.archiveURL(jobID: job.id.rawValue)
            )
            let pipeline = ReviewPipeline(
                store: store,
                skipAgent: true,
                deterministic: deterministic
            )
            try await pipeline.run(jobID: job.id)
            let after = try await store.job(id: job.id)
            guard after?.status == .succeeded else {
                throw EvalError("job \(after?.status.rawValue ?? "missing") \(after?.errorMessage ?? "")")
            }
            return try await store.findings(jobID: job.id)
        }
    }

    private func queuedEvalJob() -> Job {
        let now = Date()
        return Job(
            id: JobID.generate(),
            createdAt: now,
            updatedAt: now,
            status: .queued,
            scope: .full,
            reviewerAModelID: "eval/a",
            reviewerBModelID: "eval/b",
            judgeModelID: "eval/judge"
        )
    }

    private func withTempDataDir<T>(_ body: (URL) async throws -> T) async throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gegenlesen-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try await body(dir)
    }
}
