import Foundation
import Testing
import Vapor
import VaporTesting
@testable import GegenlesenAPI
@testable import GegenlesenCore

@Suite
struct JobsRouteTests {
    @Test
    func preferredPackEmptySHAsWithoutPatchIsAccepted() async throws {
        try await withGegenlesenApp { app in
            let archive = try tinyTarGz()
            let res = try await postJob(
                app,
                archive: archive,
                filename: "change.tar.gz",
                meta: #"{"scope":"full","base_sha":null,"head_sha":null}"#
            )
            #expect(res.status == .accepted)
            let keys = try jsonObjectKeys(res)
            #expect(keys == ["id", "queue_position", "status"])
            let body = try JSONDecoder().decode(JobAccepted.self, from: bodyData(res))
            #expect(body.status == .queued)
            #expect(body.queuePosition == 1)
        }
    }

    @Test
    func zipFilenameIsRejected() async throws {
        try await withGegenlesenApp { app in
            let res = try await postJob(
                app,
                archive: Data("notzip".utf8),
                filename: "change.zip",
                meta: #"{"scope":"full"}"#
            )
            #expect(res.status == .unsupportedMediaType)
            try assertError(res, code: "unsupported_media_type")
        }
    }

    @Test
    func zipMagicIsRejected() async throws {
        try await withGegenlesenApp { app in
            var bytes = Data([0x50, 0x4B, 0x03, 0x04])
            bytes.append(contentsOf: [UInt8](repeating: 0, count: 20))
            let res = try await postJob(
                app,
                archive: bytes,
                filename: "change.tar.gz",
                meta: #"{"scope":"full"}"#
            )
            #expect(res.status == .unsupportedMediaType)
            try assertError(res, code: "unsupported_media_type")
        }
    }

    @Test
    func missingArchiveIsBadRequest() async throws {
        try await withGegenlesenApp { app in
            try await app.testing().test(
                .POST,
                "/api/jobs",
                beforeRequest: { req in
                    try req.content.encode(["meta": #"{"scope":"full"}"#], as: .formData)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    try assertError(res, code: "bad_request")
                }
            )
        }
    }

    @Test
    func incrementalWithoutParentIsBadRequest() async throws {
        try await withGegenlesenApp { app in
            let res = try await postJob(
                app,
                archive: try tinyTarGz(),
                filename: "change.tar.gz",
                meta: #"{"scope":"incremental"}"#
            )
            #expect(res.status == .badRequest)
            try assertError(res, code: "bad_request")
        }
    }

    @Test
    func incrementalSucceededParentIsAccepted() async throws {
        try await withGegenlesenApp { app in
            let now = Date()
            let parent = Job(
                id: JobID("11111111-1111-4111-8111-111111111111"),
                createdAt: now,
                updatedAt: now,
                finishedAt: now,
                status: .succeeded,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j",
                baseSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                headSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            )
            try await app.gegenlesenStore.insertJob(parent)
            try await app.gegenlesenStore.replaceJobFiles([
                JobFile(jobID: parent.id, path: "Sources/A.swift", sha256: "ab", status: .added),
            ])
            try await app.gegenlesenStore.insertParsedFindings([
                Finding(
                    id: FindingID.generate(),
                    jobID: parent.id,
                    phase: .agent,
                    severity: .info,
                    title: "note",
                    message: "from parent",
                    filePath: "Sources/A.swift",
                    startLine: 1,
                    endLine: 1,
                    snippet: "print(2)",
                    createdAt: now
                ),
            ])
            let res = try await postJob(
                app,
                archive: try tinyTarGz(),
                filename: "change.tar.gz",
                meta: #"{"scope":"incremental","parent_job_id":"11111111-1111-4111-8111-111111111111"}"#
            )
            #expect(res.status == .accepted)
        }
    }

    @Test
    func incrementalParentNotSucceededIsUnprocessable() async throws {
        try await withGegenlesenApp { app in
            let now = Date()
            let parent = Job(
                id: JobID("11111111-1111-4111-8111-111111111111"),
                createdAt: now,
                updatedAt: now,
                status: .queued,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j",
                baseSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                headSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            )
            try await app.gegenlesenStore.insertJob(parent)
            try await app.gegenlesenStore.replaceJobFiles([
                JobFile(jobID: parent.id, path: "Sources/A.swift", sha256: "ab", status: .added),
            ])
            let res = try await postJob(
                app,
                archive: try tinyTarGz(),
                filename: "change.tar.gz",
                meta: #"{"scope":"incremental","parent_job_id":"11111111-1111-4111-8111-111111111111"}"#
            )
            #expect(res.status == .unprocessableEntity)
            try assertError(res, code: "unprocessable")
        }
    }

    @Test
    func incrementalParentMissingSHAsIsUnprocessable() async throws {
        try await withGegenlesenApp { app in
            let now = Date()
            let parent = Job(
                id: JobID("11111111-1111-4111-8111-111111111111"),
                createdAt: now,
                updatedAt: now,
                finishedAt: now,
                status: .succeeded,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j"
            )
            try await app.gegenlesenStore.insertJob(parent)
            try await app.gegenlesenStore.replaceJobFiles([
                JobFile(jobID: parent.id, path: "Sources/A.swift", sha256: "ab", status: .added),
            ])
            let res = try await postJob(
                app,
                archive: try tinyTarGz(),
                filename: "change.tar.gz",
                meta: #"{"scope":"incremental","parent_job_id":"11111111-1111-4111-8111-111111111111"}"#
            )
            #expect(res.status == .unprocessableEntity)
            try assertError(res, code: "unprocessable")
        }
    }

    @Test
    func incrementalParentWithoutFilesIsUnprocessable() async throws {
        try await withGegenlesenApp { app in
            let now = Date()
            let parent = Job(
                id: JobID("11111111-1111-4111-8111-111111111111"),
                createdAt: now,
                updatedAt: now,
                finishedAt: now,
                status: .succeeded,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j",
                baseSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                headSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            )
            try await app.gegenlesenStore.insertJob(parent)
            let res = try await postJob(
                app,
                archive: try tinyTarGz(),
                filename: "change.tar.gz",
                meta: #"{"scope":"incremental","parent_job_id":"11111111-1111-4111-8111-111111111111"}"#
            )
            #expect(res.status == .unprocessableEntity)
            try assertError(res, code: "unprocessable")
        }
    }

    @Test
    func incrementalMissingParentIsUnprocessable() async throws {
        try await withGegenlesenApp { app in
            let res = try await postJob(
                app,
                archive: try tinyTarGz(),
                filename: "change.tar.gz",
                meta: #"{"scope":"incremental","parent_job_id":"11111111-1111-4111-8111-111111111111"}"#
            )
            #expect(res.status == .unprocessableEntity)
            try assertError(res, code: "unprocessable")
        }
    }

    @Test
    func archiveOverLimitIsPayloadTooLarge() async throws {
        try await withGegenlesenApp(mutate: { $0.limits.archiveBytes = 8 }) { app in
            let res = try await postJob(
                app,
                archive: Data("0123456789abcdef".utf8),
                filename: "change.tar.gz",
                meta: #"{"scope":"full"}"#
            )
            #expect(res.status == .payloadTooLarge)
            try assertError(res, code: "payload_too_large")
        }
    }

    @Test
    func queuedArchiveOverLimitIsInsufficientStorage() async throws {
        try await withGegenlesenApp(mutate: { $0.limits.queuedArchiveBytes = 8 }) { app in
            let res = try await postJob(
                app,
                archive: Data("0123456789abcdef".utf8),
                filename: "change.tar.gz",
                meta: #"{"scope":"full"}"#
            )
            #expect(res.status.code == 507)
            try assertError(res, code: "insufficient_storage")
        }
    }

    @Test
    func unknownJobIsNotFound() async throws {
        try await withGegenlesenApp { app in
            try await app.testing().test(.GET, "/api/jobs/11111111-1111-4111-8111-111111111111") {
                res async throws in
                #expect(res.status == .notFound)
                try assertError(res, code: "not_found")
            }
        }
    }

    @Test
    func cancelRemovesCommandContainersByPrefix() async throws {
        let docker = RecordingDocker()
        try await withGegenlesenApp(docker: docker) { app in
            let job = Job(
                id: JobID("11111111-1111-4111-8111-111111111111"),
                createdAt: Date(),
                updatedAt: Date(),
                status: .deterministic,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j"
            )
            try await app.gegenlesenStore.insertJob(job)
            try await app.testing().test(.POST, "/api/jobs/\(job.id.rawValue)/cancel") {
                res async throws in
                #expect(res.status == .ok)
            }
            let prefixes = await docker.removedPrefixes
            #expect(prefixes.contains(ReviewContainers.commandPrefix(job.id)))
        }
    }

    @Test
    func cancelTerminalConflicts() async throws {
        try await withGegenlesenApp { app in
            let job = Job(
                id: JobID("11111111-1111-4111-8111-111111111111"),
                createdAt: Date(),
                updatedAt: Date(),
                finishedAt: Date(),
                status: .succeeded,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j"
            )
            try await app.gegenlesenStore.insertJob(job)
            try await app.testing().test(.POST, "/api/jobs/\(job.id.rawValue)/cancel") {
                res async throws in
                #expect(res.status == .conflict)
                try assertError(res, code: "conflict")
            }
        }
    }

    @Test
    func listAndDetailEncodeNullsAndNoExtraKeys() async throws {
        try await withGegenlesenApp { app in
            let now = Date()
            let job = Job(
                id: JobID("11111111-1111-4111-8111-111111111111"),
                createdAt: now,
                updatedAt: now,
                status: .queued,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j"
            )
            try await app.gegenlesenStore.insertJob(job)
            try await app.testing().test(.GET, "/api/jobs") { res async throws in
                #expect(res.status == .ok)
                let object = try jsonObject(res)
                #expect(Set(object.keys) == ["jobs", "total"])
                let jobs = object["jobs"] as? [[String: Any]]
                let keys = Set(jobs?.first?.keys.map { $0 } ?? [String]())
                #expect(keys == jobListKeys)
                #expect(jobs?.first?["title"] is NSNull)
                #expect(jobs?.first?["queue_position"] as? Int == 1)
            }
            try await app.testing().test(.GET, "/api/jobs/\(job.id.rawValue)") { res async throws in
                #expect(res.status == .ok)
                let object = try jsonObject(res)
                var keys = jobListKeys
                keys.insert("findings")
                keys.insert("events")
                #expect(Set(object.keys) == keys)
                #expect((object["findings"] as? [Any])?.isEmpty == true)
            }
        }
    }

    @Test
    func createSnapshotsSlotEnginesAndModels() async throws {
        try await withGegenlesenApp(mutate: { config in
            config.models.engineA = "claude"
            config.models.engineB = "codex"
            config.judgeEngine = "claude"
        }) { app in
            let res = try await postJob(
                app,
                archive: try tinyTarGz(),
                filename: "change.tar.gz",
                meta: #"{"scope":"full"}"#
            )
            #expect(res.status == .accepted)
            let accepted = try JSONDecoder().decode(JobAccepted.self, from: bodyData(res))
            try await app.testing().test(.GET, "/api/jobs/\(accepted.id.rawValue)") { res async throws in
                #expect(res.status == .ok)
                let object = try jsonObject(res)
                #expect(object["reviewer_a_engine"] as? String == "claude")
                #expect(object["reviewer_b_engine"] as? String == "codex")
                #expect(object["judge_engine"] as? String == "claude")
                #expect(object["reviewer_a_model_id"] as? String == GegenlesenConfig.example.models.modelA)
            }
            let stored = try #require(try await app.gegenlesenStore.job(id: accepted.id))
            #expect(stored.reviewerAEngine == "claude")
            #expect(stored.reviewerBEngine == "codex")
            #expect(stored.judgeEngine == "claude")
        }
    }

    @Test
    func skipAgentPipelineReachesSucceeded() async throws {
        try await withGegenlesenApp(startQueue: true) { app in
            try await seedSucceededHarvest(app.gegenlesenStore, repository: "github.com/gegenlesen/tiny")
            let archive = try packedTinyRepo()
            let created = try await postJob(
                app,
                archive: archive,
                filename: "change.tar.gz",
                meta: #"{"scope":"full","title":"tiny"}"#
            )
            #expect(created.status == .accepted)
            let accepted = try JSONDecoder().decode(JobAccepted.self, from: bodyData(created))
            let deadline = Date().addingTimeInterval(30)
            var status = JobStatus.queued
            var error: String?
            while Date() < deadline {
                try await app.testing().test(.GET, "/api/jobs/\(accepted.id.rawValue)") { res async throws in
                    #expect(res.status == .ok)
                    let object = try jsonObject(res)
                    status = JobStatus(rawValue: object["status"] as? String ?? "") ?? .queued
                    error = object["error_message"] as? String
                }
                if status.isTerminal { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(status == .succeeded, "ended \(status.rawValue) \(error ?? "")")
            try await app.testing().test(.GET, "/api/jobs/\(accepted.id.rawValue)") { res async throws in
                let object = try jsonObject(res)
                let risk = try #require(object["risk"] as? [String: Any])
                #expect(risk["verdict"] as? String == "needs_human")
                let reasons = try #require(risk["reasons"] as? [[String: Any]])
                #expect(reasons.contains { $0["code"] as? String == "reviewers_skipped" })
            }
            let stored = try #require(try await app.gegenlesenStore.job(id: accepted.id))
            let timings = try #require(stored.timings)
            #expect(timings.unpackMS != nil)
            #expect(timings.identifyMS != nil)
            #expect(timings.deterministicMS != nil)
            #expect(timings.reviewMS == nil)
            #expect(timings.judgeMS == nil)
        }
    }

    @Test
    func riskLabelRequiresSucceededJobWithAssessment() async throws {
        try await withGegenlesenApp { app in
            let now = Date()
            let assessment = RiskAssessment(
                verdict: .autoApprove,
                mode: .shadow,
                score: 1,
                appetite: 1,
                reasons: []
            )
            let job = Job(
                id: JobID("11111111-1111-4111-8111-111111111111"),
                createdAt: now,
                updatedAt: now,
                finishedAt: now,
                status: .succeeded,
                scope: .full,
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j",
                risk: assessment
            )
            try await app.gegenlesenStore.insertJob(job)
            try await app.testing().test(
                .POST,
                "/api/jobs/\(job.id.rawValue)/risk-label",
                beforeRequest: { req async throws in
                    try req.content.encode(RiskLabelRequest(safeUnread: true))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let object = try jsonObject(res)
                let risk = try #require(object["risk"] as? [String: Any])
                #expect(risk["safe_unread"] as? Bool == true)
                #expect(risk["verdict"] as? String == "auto_approve")
            }
        }
    }

    @Test
    func identifyFailureIsNoChangeSet() async throws {
        try await withGegenlesenApp(startQueue: true) { app in
            let archive = try tinyTarGz()
            let created = try await postJob(
                app,
                archive: archive,
                filename: "change.tar.gz",
                meta: #"{"scope":"full"}"#
            )
            let accepted = try JSONDecoder().decode(JobAccepted.self, from: bodyData(created))
            let deadline = Date().addingTimeInterval(20)
            var status = JobStatus.queued
            var error: String?
            while Date() < deadline {
                try await app.testing().test(.GET, "/api/jobs/\(accepted.id.rawValue)") { res async throws in
                    let object = try jsonObject(res)
                    status = JobStatus(rawValue: object["status"] as? String ?? "") ?? .queued
                    error = object["error_message"] as? String
                }
                if status.isTerminal { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(status == .failed)
            #expect(error == "no_change_set")
        }
    }

    @Test
    func reviewFailsHarvestRequiredWithoutSucceededHarvest() async throws {
        try await withGegenlesenApp(startQueue: true) { app in
            let archive = try packedTinyRepo()
            let created = try await postJob(
                app,
                archive: archive,
                filename: "change.tar.gz",
                meta: #"{"scope":"full","title":"tiny"}"#
            )
            let accepted = try JSONDecoder().decode(JobAccepted.self, from: bodyData(created))
            let (status, error) = try await waitForTerminal(app, id: accepted.id)
            #expect(status == .failed)
            #expect(error == "harvest_required")
        }
    }

    @Test
    func reviewFailsRepositoryUnresolvedWithoutOrigin() async throws {
        try await withGegenlesenApp(startQueue: true) { app in
            let archive = try packedTinyRepo(origin: nil)
            let created = try await postJob(
                app,
                archive: archive,
                filename: "change.tar.gz",
                meta: #"{"scope":"full","title":"tiny"}"#
            )
            let accepted = try JSONDecoder().decode(JobAccepted.self, from: bodyData(created))
            let (status, error) = try await waitForTerminal(app, id: accepted.id)
            #expect(status == .failed)
            #expect(error == "repository_unresolved")
        }
    }

    @Test
    func failedHarvestDoesNotUnlockReview() async throws {
        try await withGegenlesenApp(startQueue: true) { app in
            try await seedHarvest(
                app.gegenlesenStore,
                repository: "github.com/gegenlesen/tiny",
                status: .failed,
                errorMessage: "harvest_judge_failed"
            )
            let archive = try packedTinyRepo()
            let created = try await postJob(
                app,
                archive: archive,
                filename: "change.tar.gz",
                meta: #"{"scope":"full","title":"tiny"}"#
            )
            let accepted = try JSONDecoder().decode(JobAccepted.self, from: bodyData(created))
            let (status, error) = try await waitForTerminal(app, id: accepted.id)
            #expect(status == .failed)
            #expect(error == "harvest_required")
        }
    }
}

private let jobListKeys: Set<String> = [
    "id", "title", "status", "scope", "parent_job_id", "repository",
    "reviewer_a_engine", "reviewer_a_model_id",
    "reviewer_b_engine", "reviewer_b_model_id",
    "judge_engine", "judge_model_id",
    "base_sha", "head_sha", "queue_position", "summary",
    "created_at", "started_at", "finished_at", "error_message", "risk",
]

private func postJob(
    _ app: Application,
    archive: Data,
    filename: String,
    meta: String
) async throws -> TestingHTTPResponse {
    var captured: TestingHTTPResponse?
    try await app.testing().test(
        .POST,
        "/api/jobs",
        beforeRequest: { req in
            try req.content.encode(
                JobPostBody(archive: File(data: .init(data: archive), filename: filename), meta: meta),
                as: .formData
            )
        },
        afterResponse: { res async in
            captured = res
        }
    )
    return try #require(captured)
}

private struct JobPostBody: Content {
    var archive: File
    var meta: String
}

private func assertError(_ res: TestingHTTPResponse, code: String) throws {
    let object = try jsonObject(res)
    let error = try #require(object["error"] as? [String: Any])
    #expect(error["code"] as? String == code)
    #expect(error["message"] is String)
    #expect(Set(object.keys) == ["error"])
}

private func bodyData(_ res: TestingHTTPResponse) -> Data {
    Data(res.body.readableBytesView)
}

private func jsonObject(_ res: TestingHTTPResponse) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: bodyData(res))
    return try #require(object as? [String: Any])
}

private func jsonObjectKeys(_ res: TestingHTTPResponse) throws -> Set<String> {
    Set(try jsonObject(res).keys)
}

private func tinyTarGz() throws -> Data {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gegenlesen-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "hi\n".write(to: dir.appendingPathComponent("README"), atomically: true, encoding: .utf8)
    let archive = FileManager.default.temporaryDirectory
        .appendingPathComponent("gegenlesen-empty-\(UUID().uuidString).tar.gz")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
    process.arguments = ["-czf", archive.path, "-C", dir.path, "."]
    process.environment = ["PATH": "/usr/bin:/bin", "COPYFILE_DISABLE": "1"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw APIError.badRequest("bsdtar failed")
    }
    return try Data(contentsOf: archive)
}

private func waitForTerminal(_ app: Application, id: JobID, seconds: TimeInterval = 30) async throws -> (JobStatus, String?) {
    let deadline = Date().addingTimeInterval(seconds)
    var status = JobStatus.queued
    var error: String?
    while Date() < deadline {
        try await app.testing().test(.GET, "/api/jobs/\(id.rawValue)") { res async throws in
            let object = try jsonObject(res)
            status = JobStatus(rawValue: object["status"] as? String ?? "") ?? .queued
            error = object["error_message"] as? String
        }
        if status.isTerminal { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    return (status, error)
}

private func seedSucceededHarvest(_ store: Store, repository: String) async throws {
    try await seedHarvest(store, repository: repository, status: .succeeded, errorMessage: nil)
}

private func seedHarvest(
    _ store: Store,
    repository: String,
    status: JobStatus,
    errorMessage: String?
) async throws {
    let now = Date()
    let job = Job(
        id: JobID.generate(),
        createdAt: now,
        updatedAt: now,
        finishedAt: now,
        status: status,
        scope: .full,
        title: "harvest tree.tar.gz",
        repository: repository,
        reviewerAModelID: "a",
        reviewerBModelID: "b",
        judgeModelID: "j",
        errorMessage: errorMessage
    )
    try await store.insertJob(job)
}

private func packedTinyRepo(origin: String? = "git@github.com:gegenlesen/tiny.git") throws -> Data {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gegenlesen-pack-\(UUID().uuidString)", isDirectory: true)
    let repo = dir.appendingPathComponent("tiny")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=gegenlesen",
            "-c", "user.email=gegenlesen@localhost",
            "-c", "init.defaultBranch=main",
            "-c", "safe.directory=*",
        ] + args
        process.currentDirectoryURL = repo
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": dir.appendingPathComponent("home").path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
        ]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw APIError.badRequest("git failed")
        }
    }

    try git(["init"])
    if let origin {
        try git(["remote", "add", "origin", origin])
    }
    try "v1\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"])
    try git(["commit", "-m", "v1"])
    try "v2\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"])
    try git(["commit", "-m", "v2"])

    let head = try RepoPacker.resolveHead(cwd: repo)
    let base = try RepoPacker.resolveBase(cwd: repo, ref: "HEAD^")
    return try RepoPacker.pack(cwd: repo, base: base, head: head).archive
}
