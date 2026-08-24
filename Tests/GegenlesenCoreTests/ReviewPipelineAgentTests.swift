import Foundation
import Testing
@testable import GegenlesenCore
@testable import GegenlesenDeterministic

@Suite
struct ReviewPipelineAgentTests {
    @Test
    func reviewFailureClassPrefersProviderAuth() {
        #expect(
            ReviewFailureClass.classify(
                errorMessage: "reviewer_no_findings_file",
                payloadJSON: #"{"provider":"openrouter","status":401}"#
            ) == .providerAuth
        )
        #expect(
            ReviewFailureClass.classify(
                errorMessage: "reviewer_no_findings_file",
                payloadJSON: nil
            ) == .noFindingsFile
        )
        #expect(
            ReviewFailureClass.classify(
                errorMessage: "boom",
                payloadJSON: nil
            ) == .reviewerFailed
        )
        #expect(ReviewFailureClass.providerAuthHTTPStatus(in: #"HTTP 403 {"code":403}"#) == 403)
        #expect(
            ReviewFailureClass.providerAuthHTTPStatus(
                in: #"{"error":{"message":"User not found.","code":401}}"#
            ) == 401
        )
        #expect(ReviewFailureClass.providerAuthHTTPStatus(in: "User not found.") == nil)
        #expect(ReviewFailureClass.providerAuthHTTPStatus(in: "docker not wired") == nil)
    }


    @Test
    func skipAgentPackedRepoSucceedsWithoutReviewer() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let pipeline = ReviewPipeline(store: store, skipAgent: true, reviewer: nil)
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                #expect(after.containerNameA == nil)
                #expect(after.risk != nil)
                let timings = try #require(after.timings)
                #expect(timings.unpackMS != nil)
                #expect(timings.identifyMS != nil)
                #expect(timings.deterministicMS != nil)
                #expect(timings.reviewMS == nil)
                #expect(timings.judgeMS == nil)
                let findings = try await store.findings(jobID: job.id)
                #expect(!findings.contains { $0.phase == .agent })
                let context = store.blobs.workspaceURL(jobID: job.id.rawValue)
                    .appendingPathComponent(".gegenlesen/context.md")
                #expect(FileManager.default.fileExists(atPath: context.path))
                let text = try String(contentsOf: context, encoding: .utf8)
                #expect(text.contains("Project context"))
            }
        }
    }

    @Test
    func noValidFindingsFileFailsWhenNewWork() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: EmptyReviewer()
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .failed)
                #expect(after.errorMessage == "no_findings_file")
                #expect(after.containerNameA == "gegenlesen-review-\(job.id.rawValue)-a")
                let risk = try #require(after.risk)
                #expect(risk.verdict == .needsHuman)
                #expect(risk.reasons.contains { $0.code == "no_findings_file" })
                let events = try await store.events(jobID: job.id)
                let failed = try #require(events.first { $0.message == "review_failed" })
                #expect(failed.payloadJSON?.contains("no_findings_file") == true)
                #expect(failed.payloadJSON?.contains("reviewer_no_findings_file") == true)
                let timings = try #require(after.timings)
                #expect(timings.reviewMS != nil)
            }
        }
    }

    @Test
    func providerAuthFailurePersistsCompactRiskAndPayload() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: ProviderAuthReviewer()
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .failed)
                #expect(after.errorMessage == "provider_auth")
                let risk = try #require(after.risk)
                #expect(risk.reasons.contains { $0.code == "provider_auth" })
                let events = try await store.events(jobID: job.id)
                let failed = try #require(events.first { $0.message == "review_failed" })
                #expect(failed.payloadJSON?.contains("\"status\":401") == true)
                #expect(failed.payloadJSON?.contains("openrouter") == true)
            }
        }
    }

    @Test
    func reviewerFindingsPersistAndJobSucceeds() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let workspace = store.blobs.workspaceURL(jobID: "will-replace")
            _ = workspace
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))

                let fake = FakeReviewer()
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: fake,
                    judge: UnavailableJudge()
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                #expect(after.containerNameA == "gegenlesen-review-\(job.id.rawValue)-a")
                #expect(after.risk != nil)
                let timings = try #require(after.timings)
                #expect(timings.reviewMS != nil)
                #expect(timings.judgeMS != nil)
                let findings = try await store.findings(jobID: job.id)
                #expect(findings.contains { $0.phase == .agent && $0.reviewerSlot == .modelA })
                #expect(findings.contains { $0.judgeVerdict == .unavailable })
            }
        }
    }

    @Test
    func emptyAgentFindingsSkipJudge() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let judge = RecordingJudge()
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: EmptyValidReviewer(),
                    judge: judge
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                #expect(judge.ran == false)
            }
        }
    }

    @Test
    func judgeFailDoesNotFailJobAndPersistsPostJudge() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: FakeReviewer(),
                    judge: UnavailableJudge()
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                #expect(after.containerName == "gegenlesen-judge-\(job.id.rawValue)")
                let post = store.blobs.findingsURL(jobID: job.id.rawValue, stage: "post-judge")
                #expect(FileManager.default.fileExists(atPath: post.path))
                let pre = store.blobs.findingsURL(jobID: job.id.rawValue, stage: "pre-judge")
                #expect(FileManager.default.fileExists(atPath: pre.path))
            }
        }
    }

    @Test
    func hostForcedDropPersistsAndCountsSummary() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: MismatchedEvidenceReviewer(),
                    judge: KeepAllJudge()
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                let findings = try await store.findings(jobID: job.id)
                #expect(findings.contains { $0.judgeVerdict == .drop })
                let summary = try await store.summary(jobID: job.id)
                #expect(summary.dropped == 1)
            }
        }
    }

    @Test
    func commandExitZeroJSONLPersistsFindings() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                try await store.insertRule(
                    sampleRule(id: "cmd", payload: .command(argv: ["true"], timeoutSec: 5))
                )
                let jsonl = """
                {"title":"cmd hit","message":"from sandbox","severity":"error","file_path":"Sources/A.swift","start_line":1,"end_line":1,"snippet":"print(2)"}
                """
                let docker = RecordingDocker(
                    result: DockerResult(exitCode: 0, stdout: Data(jsonl.utf8))
                )
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: true,
                    deterministic: DeterministicEngine(docker: docker)
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                let findings = try await store.findings(jobID: job.id)
                #expect(findings.contains { $0.phase == .deterministic && $0.title == "cmd hit" })
                let cmd = try #require(findings.first { $0.title == "cmd hit" })
                #expect(cmd.judgeVerdict == nil)
                #expect(cmd.evidenceOK == true)
                let requests = await docker.requests
                let args = try #require(requests.first).dockerCLIArguments()
                #expect(args.contains("--network"))
                #expect(args.contains("none"))
                #expect(!args.contains { $0.contains("ANTHROPIC_API_KEY") })
                #expect(!args.contains { $0.contains("OPENAI_API_KEY") })
            }
        }
    }

    @Test
    func commandNonzeroExitDoesNotFailJob() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                try await store.insertRule(
                    sampleRule(id: "cmd", payload: .command(argv: ["false"], timeoutSec: 5))
                )
                let docker = RecordingDocker(
                    result: DockerResult(exitCode: 1, stderr: Data("oasdiff missing\n".utf8))
                )
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: true,
                    deterministic: DeterministicEngine(docker: docker)
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                let findings = try await store.findings(jobID: job.id)
                #expect(findings.isEmpty)
                let events = try await store.events(jobID: job.id)
                #expect(events.contains { $0.level == .warning && $0.message == "command_error" })
            }
        }
    }

    @Test
    func requireHarvestFailsUnknownRepo() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                var job = queuedJob()
                job.repository = "github.com/acme/app"
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                try await ReviewPipeline(
                    store: store,
                    skipAgent: true,
                    reviewer: nil,
                    requireHarvest: true
                ).run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .failed)
                #expect(after.errorMessage == "harvest_required")
            }
        }
    }

    @Test
    func requireHarvestFailsUnresolvedRepository() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                try await ReviewPipeline(
                    store: store,
                    skipAgent: true,
                    reviewer: nil,
                    requireHarvest: true
                ).run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .failed)
                #expect(after.errorMessage == "repository_unresolved")
            }
        }
    }

    @Test
    func requireHarvestPassesAfterSucceededHarvest() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let now = Date()
                var harvest = sampleJob(id: "harvest-ok", status: .succeeded, finishedAt: now)
                harvest.title = "harvest tree.tar.gz"
                harvest.repository = "github.com/acme/app"
                try await store.insertJob(harvest)
                var job = queuedJob()
                job.repository = "github.com/acme/app"
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                try await ReviewPipeline(
                    store: store,
                    skipAgent: true,
                    reviewer: nil,
                    requireHarvest: true
                ).run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
            }
        }
    }

    @Test
    func requireHarvestIgnoresFailedHarvest() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let now = Date()
                var harvest = sampleJob(id: "harvest-bad", status: .failed, finishedAt: now)
                harvest.title = "harvest tree.tar.gz"
                harvest.repository = "github.com/acme/app"
                harvest.errorMessage = "harvest_judge_failed"
                try await store.insertJob(harvest)
                var job = queuedJob()
                job.repository = "github.com/acme/app"
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                try await ReviewPipeline(
                    store: store,
                    skipAgent: true,
                    reviewer: nil,
                    requireHarvest: true
                ).run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .failed)
                #expect(after.errorMessage == "harvest_required")
            }
        }
    }
}

struct ProviderAuthReviewer: ReviewerRunning {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        AgentReviewResult(
            findings: [],
            validFileCount: 0,
            failed: true,
            errorMessage: "User not found.",
            payloadJSON: JobEvent.payloadJSON([
                "body": "User not found.",
                "error_class": "provider_auth",
                "message": "User not found.",
                "provider": "openrouter",
                "status": 401,
            ]),
            containerNameA: ReviewContainers.slot(request.job.id, .modelA),
            containerNameB: ReviewContainers.slot(request.job.id, .modelB),
            containerName: ReviewContainers.judge(request.job.id)
        )
    }
}

struct EmptyReviewer: ReviewerRunning {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        AgentReviewResult(
            findings: [],
            validFileCount: 0,
            failed: request.newWork,
            errorMessage: request.newWork ? "reviewer_no_findings_file" : nil,
            containerNameA: ReviewContainers.slot(request.job.id, .modelA),
            containerNameB: ReviewContainers.slot(request.job.id, .modelB),
            containerName: ReviewContainers.judge(request.job.id)
        )
    }
}

struct EmptyValidReviewer: ReviewerRunning {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        AgentReviewResult(
            findings: [],
            validFileCount: 2,
            failed: false,
            containerNameA: ReviewContainers.slot(request.job.id, .modelA),
            containerNameB: ReviewContainers.slot(request.job.id, .modelB),
            containerName: ReviewContainers.judge(request.job.id)
        )
    }
}

struct UnavailableJudge: JudgeRunning {
    func run(_ request: JudgeRequest) async -> JudgeRunResult {
        JudgeRunResult(outcome: .containerFailed, containerName: ReviewContainers.judge(request.job.id))
    }
}

final class RecordingJudge: JudgeRunning, @unchecked Sendable {
    var ran = false
    func run(_ request: JudgeRequest) async -> JudgeRunResult {
        ran = true
        return JudgeRunResult(outcome: .containerFailed, containerName: ReviewContainers.judge(request.job.id))
    }
}

struct KeepAllJudge: JudgeRunning {
    func run(_ request: JudgeRequest) async -> JudgeRunResult {
        JudgeRunResult(
            outcome: .verdicts(JudgeFile(verdicts: [])),
            containerName: ReviewContainers.judge(request.job.id)
        )
    }
}

struct MismatchedEvidenceReviewer: ReviewerRunning {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        let finding = Finding(
            id: FindingID.generate(),
            jobID: request.job.id,
            phase: .agent,
            reviewerSlot: .modelA,
            severity: .error,
            title: "bad evidence",
            message: "snippet does not match",
            filePath: "Sources/A.swift",
            startLine: 1,
            endLine: 1,
            snippet: "this-is-not-in-the-file",
            evidenceOK: false,
            createdAt: Date()
        )
        return AgentReviewResult(
            findings: [finding],
            validFileCount: 1,
            failed: false,
            containerNameA: ReviewContainers.slot(request.job.id, .modelA),
            containerNameB: ReviewContainers.slot(request.job.id, .modelB),
            containerName: ReviewContainers.judge(request.job.id)
        )
    }
}

struct FakeReviewer: ReviewerRunning {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        let finding = Finding(
            id: FindingID.generate(),
            jobID: request.job.id,
            phase: .agent,
            reviewerSlot: .modelA,
            severity: .info,
            title: "note",
            message: "from fake reviewer",
            filePath: "Sources/A.swift",
            startLine: 1,
            endLine: 1,
            snippet: "print(2)",
            createdAt: Date()
        )
        return AgentReviewResult(
            findings: [finding],
            validFileCount: 1,
            failed: false,
            containerNameA: "gegenlesen-review-\(request.job.id.rawValue)-a",
            containerNameB: "gegenlesen-review-\(request.job.id.rawValue)-b",
            containerName: "gegenlesen-judge-\(request.job.id.rawValue)"
        )
    }
}

private func withPackedRepo(dir: URL, _ body: (URL) async throws -> Void) async throws {
    try await withTempDir("pipe-pack") { repo in
        try writeFile("Sources/A.swift", "print(2)\n", in: repo)
        try writeFile(
            ".gegenlesen/diff.patch",
            """
            diff --git a/Sources/A.swift b/Sources/A.swift
            new file mode 100644
            --- /dev/null
            +++ b/Sources/A.swift
            @@ -0,0 +1 @@
            +print(2)
            """,
            in: repo
        )
        let archive = dir.appendingPathComponent("change-\(UUID().uuidString).tar.gz")
        try gzipTarCreate(from: repo, to: archive)
        try await body(archive)
    }
}

private func queuedJob() -> Job {
    let now = Date()
    return Job(
        id: JobID.generate(),
        createdAt: now,
        updatedAt: now,
        status: .queued,
        scope: .full,
        reviewerAModelID: "anthropic/claude-sonnet-4-5",
        reviewerBModelID: "openai/gpt-5.2",
        judgeModelID: "anthropic/claude-sonnet-4-5"
    )
}
