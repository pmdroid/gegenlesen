import Foundation
import Testing
@testable import GegenlesenCore
@testable import GegenlesenDeterministic

@Suite
struct ReviewPipelineAgentTests {
    @Test(arguments: [false, true])
    func singleReviewerExperimentPreservesJudgeAndRecordsPolicy(hasFinding: Bool) async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let judge = JudgeInputRecordingJudge()
                try await ReviewPipeline(
                    store: store, skipAgent: false,
                    reviewer: SingleReviewerFixture(hasFinding: hasFinding), judge: judge,
                    reviewStrictMode: true, singleReviewerExperiment: true
                ).run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                #expect(after.containerNameB == nil)
                #expect(!after.reviewDegraded)
                #expect(after.risk?.verdict == .needsHuman)
                #expect(after.risk?.reasons.contains { $0.code == "single_reviewer_experiment" } == true)
                #expect(after.risk?.reasons.contains { $0.code == "reviewer_file_missing" } == false)
                #expect((judge.input != nil) == hasFinding)
                let findings = try await store.findings(jobID: job.id)
                #expect(findings.filter { $0.judgeVerdict == .keep }.count == (hasFinding ? 1 : 0))
                let policy = try #require(try await store.events(jobID: job.id).first { $0.message == "review_policy" }?.payloadJSON)
                let value = try #require(JSONSerialization.jsonObject(with: Data(policy.utf8)) as? [String: Any])
                #expect(value["requested_slots"] as? [String] == ["model_a"])
            }
        }
    }

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
        #expect(
            ReviewFailureClass.classify(
                errorMessage: ReviewFailureClass.containerStartFailed.rawValue,
                payloadJSON: #"{"message":"exec /usr/local/bin/entrypoint.sh: resource temporarily unavailable","stderr":"exec /usr/local/bin/entrypoint.sh: resource temporarily unavailable"}"#
            ) == .containerStartFailed
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
    func expiredQueueBudgetSkipsAllStages() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            var job = queuedJob()
            job.deadlineAt = Date().addingTimeInterval(-1)
            try await store.insertJob(job)
            try await ReviewPipeline(store: store).run(jobID: job.id)
            let after = try #require(try await store.job(id: job.id))
            #expect(after.status == .failed)
            #expect(after.errorMessage == "review_deadline_exceeded")
            #expect(after.risk?.verdict == .needsHuman)
            #expect(after.timings == nil)
            #expect(try await store.expireReview(id: job.id) == false)
        }
    }

    @Test
    func deadlinePreemptionKeepsItsFailureReason() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                try await store.write { db in
                    try db.execute(sql: "CREATE TRIGGER expire_on_review BEFORE INSERT ON job_events WHEN NEW.message = 'reviewing' BEGIN UPDATE jobs SET deadline_at = '2000-01-01T00:00:00Z' WHERE id = NEW.job_id; END")
                }
                try await ReviewPipeline(store: store, skipAgent: false, reviewer: nil).run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .failed)
                #expect(after.errorMessage == "review_deadline_exceeded")
                #expect(after.risk?.reasons.map(\.code) == ["review_deadline_exceeded"])
                #expect(try await !store.events(jobID: job.id).contains { $0.message == "review_failed" })
            }
        }
    }

    @Test
    func deadlinePreemptionKeepsConfiguredRisk() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let job = queuedJob()
            try await store.insertJob(job)
            try await store.write { db in
                try db.execute(sql: "CREATE TRIGGER expire_on_dequeue BEFORE INSERT ON job_events WHEN NEW.message = 'dequeued' BEGIN UPDATE jobs SET deadline_at = '2000-01-01T00:00:00Z' WHERE id = NEW.job_id; END")
            }
            var risk = RiskConfig.v1
            risk.mode = .enforce
            risk.appetite = 4
            try await ReviewPipeline(store: store, risk: risk).run(jobID: job.id)
            let after = try #require(try await store.job(id: job.id))
            #expect(after.status == .failed)
            #expect(after.risk?.reasons.map(\.code) == ["review_deadline_exceeded"])
            #expect(after.risk?.mode == .enforce)
            #expect(after.risk?.appetite == 4)
        }
    }

    @Test
    func incompleteScannerCannotApproveAReview() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                try await ReviewPipeline(store: store, skipAgent: false, scanner: IncompleteScanner(), reviewer: EmptyValidReviewer()).run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .failed)
                #expect(after.risk?.verdict == .needsHuman)
                #expect(after.errorMessage == "scanner_timeout")
            }
        }
    }

    @Test
    func elapsedDeadlinePreventsSuccessfulCompletion() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            var job = queuedJob()
            job.status = .judging
            job.deadlineAt = Date().addingTimeInterval(-1)
            try await store.insertJob(job)
            let after = try await store.apply(jobID: job.id, event: .judgeFinished)
            #expect(after.status == .failed)
            #expect(after.errorMessage == "review_deadline_exceeded")
            #expect(after.risk?.verdict == .needsHuman)
        }
    }

    @Test
    func failedRiskWriteCannotPublishSuccess() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            var job = queuedJob()
            job.status = .judging
            try await store.insertJob(job)
            try await store.write { db in
                try db.execute(sql: "CREATE TRIGGER reject_risk BEFORE UPDATE OF risk_json ON jobs BEGIN SELECT RAISE(ABORT, 'risk write failed'); END")
            }
            let assessment = RiskAssessment(verdict: .needsHuman, mode: .shadow, score: 5, appetite: 1, reasons: [])
            do {
                try await store.completeReview(id: job.id, event: .judgeFinished, assessment: assessment, risk: .v1)
                Issue.record("risk write unexpectedly succeeded")
            } catch {}
            let after = try #require(try await store.job(id: job.id))
            #expect(after.status == .judging)
            #expect(after.risk == nil)
            #expect(try await store.events(jobID: job.id).isEmpty)
        }
    }

    @Test
    func completedReviewCannotBeExpired() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            var job = queuedJob()
            job.status = .succeeded
            try await store.insertJob(job)
            #expect(try await store.expireReview(id: job.id) == false)
            #expect(try await store.job(id: job.id)?.status == .succeeded)
        }
    }

    @Test(arguments: [false, true])
    func runningDeadlineRetainsPartialFindings(scanner: Bool) async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                var job = queuedJob()
                job.deadlineAt = Date().addingTimeInterval(3)
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let started = ContinuousClock.now
                try await ReviewPipeline(store: store, skipAgent: false,
                    scanner: scanner ? CancelledPartialScanner() : nil,
                    reviewer: CancelledPartialReviewer()).run(jobID: job.id)
                #expect(ContinuousClock.now - started < .seconds(5))
                let after = try #require(try await store.job(id: job.id))
                #expect(after.errorMessage == "review_deadline_exceeded")
                #expect(after.risk?.verdict == .needsHuman)
                let findings = try await store.findings(jobID: job.id)
                #expect(findings.count == 1)
                #expect(findings.first?.judgeVerdict == .unavailable)
            }
        }
    }

    @Test
    func reviewUsesPreparedContextWithoutReindexing() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await store.insertContextNote(ContextNote(kind: .architecture, title: "Architecture", body: "Accepted architecture"))
            try await store.insertContextNote(ContextNote(title: "Operator", body: "Accepted operator note"))
            let chunks = [
                ContextChunk(id: "current", kind: .file, ref: "Sources/A.swift", text: "Current source context", contentSHA256: ContentHash.sha256(Data("print(2)\n".utf8))),
                ContextChunk(id: "stale", kind: .file, ref: "Sources/A.swift", text: "Stale source context", contentSHA256: "old"),
                ContextChunk(id: "foreign", kind: .rule, ref: "foreign-rule", text: "Foreign rule context", contentSHA256: "other"),
            ].map { chunk in
                var copy = chunk
                copy.embedding = EmbeddingVector.encode([1, 0])
                return copy
            }
            try await store.upsertChunks(chunks)
            let embedder = ReviewContextEmbedder()
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                try await ReviewPipeline(store: store, skipAgent: true, embedder: embedder).run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                let context = store.blobs.workspaceURL(jobID: job.id.rawValue).appendingPathComponent(".gegenlesen/context.md")
                let text = try String(contentsOf: context, encoding: .utf8)
                #expect(text.contains("Accepted architecture"))
                #expect(text.contains("Accepted operator note"))
                #expect(text.contains("Current source context"))
                #expect(!text.contains("Stale source context"))
                #expect(!text.contains("Foreign rule context"))
                #expect(await embedder.inputs.count == 1)
                #expect(await embedder.inputs.first?.count == 1)
                #expect(try await store.chunks(kind: .file).count == 2)
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
    func containerStartFailedKeepsStderrOnJobEvent() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: ContainerStartFailedReviewer()
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .failed)
                #expect(after.errorMessage == ReviewFailureClass.containerStartFailed.rawValue)
                let events = try await store.events(jobID: job.id)
                let failed = try #require(events.first { $0.message == "review_failed" })
                #expect(failed.payloadJSON?.contains("container_start_failed") == true)
                #expect(failed.payloadJSON?.contains("resource temporarily unavailable") == true)
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

    @Test
    func crossSlotDuplicatesMergeBeforeJudge() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await withPackedRepo(dir: dir) { archive in
                let job = queuedJob()
                try await store.insertJob(job)
                try FileManager.default.copyItem(at: archive, to: store.blobs.archiveURL(jobID: job.id.rawValue))
                let judge = JudgeInputRecordingJudge()
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: false,
                    reviewer: BothSlotsSameDefectReviewer(),
                    judge: judge
                )
                try await pipeline.run(jobID: job.id)
                let after = try #require(try await store.job(id: job.id))
                #expect(after.status == .succeeded)
                let findings = try await store.findings(jobID: job.id)
                let kept = findings.filter { $0.judgeVerdict == .keep }
                #expect(kept.count == 1)
                let drops = findings.filter { $0.judgeVerdict == .drop }
                #expect(drops.count == 1)
                #expect(drops[0].judgeRationale?.contains("duplicate of") == true)
                #expect(drops[0].judgeRationale?.contains("model_a + model_b") == true)
                let input = try #require(judge.input)
                #expect(input.candidates.count == 1)
                #expect(input.candidates[0].sources == ["model_a", "model_b"])
                #expect(input.candidates[0].agreement == "agreed")
            }
        }
    }
}

struct BothSlotsSameDefectReviewer: ReviewerRunning {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        func make(_ slot: ReviewerSlot) -> Finding {
            Finding(
                id: FindingID.generate(),
                jobID: request.job.id,
                phase: .agent,
                reviewerSlot: slot,
                severity: .warning,
                title: "CacheDescribe can run with a disabled description cache",
                message: "The describe path silently tolerates a disabled cache.",
                filePath: "Sources/A.swift",
                startLine: 1,
                endLine: 1,
                snippet: "print(2)",
                confidence: slot == .modelA ? 0.8 : 0.6,
                createdAt: Date()
            )
        }
        return AgentReviewResult(
            findings: [make(.modelA), make(.modelB)],
            validFileCount: 2,
            failed: false,
            containerNameA: ReviewContainers.slot(request.job.id, .modelA),
            containerNameB: ReviewContainers.slot(request.job.id, .modelB),
            containerName: ReviewContainers.judge(request.job.id)
        )
    }
}

final class JudgeInputRecordingJudge: JudgeRunning, @unchecked Sendable {
    var input: JudgeInputFile?

    func run(_ request: JudgeRequest) async -> JudgeRunResult {
        let url = request.workspace.root.appendingPathComponent(".gegenlesen/judge-input.json")
        if let data = try? Data(contentsOf: url) {
            input = try? JSONDecoder().decode(JudgeInputFile.self, from: data)
        }
        return JudgeRunResult(
            outcome: .verdicts(JudgeFile(verdicts: (input?.candidates ?? []).map {
                JudgeVerdictRow(findingID: $0.id, verdict: .keep, rationale: "confirmed in source")
            })),
            containerName: ReviewContainers.judge(request.job.id)
        )
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

struct ContainerStartFailedReviewer: ReviewerRunning {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        let detail = "exec /usr/local/bin/entrypoint.sh: resource temporarily unavailable"
        return AgentReviewResult(
            findings: [],
            validFileCount: 0,
            failed: true,
            errorMessage: ReviewFailureClass.containerStartFailed.rawValue,
            payloadJSON: JobEvent.payloadJSON([
                "error_class": ReviewFailureClass.containerStartFailed.rawValue,
                "message": detail,
                "stderr": detail,
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

struct SingleReviewerFixture: ReviewerRunning {
    let hasFinding: Bool

    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        #expect(request.singleReviewerExperiment)
        var result = await FakeReviewer().run(request)
        result.findings = hasFinding ? result.findings : []
        result.containerNameB = nil
        return result
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

private actor ReviewContextEmbedder: EmbeddingClient {
    nonisolated let model = "test"
    nonisolated let dimensions = 2
    var inputs: [[String]] = []

    func embed(_ texts: [String]) async throws -> [[Float]] {
        inputs.append(texts)
        return texts.map { _ in [1, 0] }
    }
}

private struct CancelledPartialReviewer: ReviewerRunning {
    func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        try? await Task.sleep(for: .seconds(10))
        let finding = Finding(
            id: FindingID.generate(), jobID: request.job.id, phase: .agent,
            severity: .warning, title: "Partial finding", message: "Needs verification",
            filePath: "Sources/A.swift", startLine: 1, endLine: 1, snippet: "print(2)",
            judgeVerdict: .unavailable, createdAt: Date()
        )
        return AgentReviewResult(findings: [finding], validFileCount: 0, failed: true,
            containerNameA: "a", containerNameB: "b", containerName: "judge")
    }
}

private struct IncompleteScanner: ScannerRunning {
    func run(jobID: JobID, files: [JobFile], workspace: Workspace, timeout: Duration,
        isCancelled: (@Sendable () async -> Bool)?) async -> DeterministicRunResult {
        DeterministicRunResult(drafts: [], timedOut: true)
    }
}

private struct CancelledPartialScanner: ScannerRunning {
    func run(jobID: JobID, files: [JobFile], workspace: Workspace, timeout: Duration,
        isCancelled: (@Sendable () async -> Bool)?) async -> DeterministicRunResult {
        try? await Task.sleep(for: .seconds(10))
        let draft = FindingDraft(phase: .deterministic, severity: .warning,
            title: "Partial finding", message: "Needs verification", filePath: "Sources/A.swift",
            startLine: 1, endLine: 1, snippet: "print(2)", requiresJudge: true, evidenceOK: true)
        return DeterministicRunResult(drafts: [draft], timedOut: true)
    }
}
