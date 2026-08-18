import Foundation
import Testing
import VaporTesting
@testable import MeisterAPI
@testable import MeisterCore

@Suite
struct JobsRouteTests {
    @Test
    func preferredPackEmptySHAsWithoutPatchIsAccepted() async throws {
        try await withMeisterApp { app in
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
        try await withMeisterApp { app in
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
        try await withMeisterApp { app in
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
        try await withMeisterApp { app in
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
        try await withMeisterApp { app in
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
        try await withMeisterApp { app in
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
            try await app.meisterStore.insertJob(parent)
            try await app.meisterStore.replaceJobFiles([
                JobFile(jobID: parent.id, path: "Sources/A.swift", sha256: "ab", status: .added),
            ])
            try await app.meisterStore.insertParsedFindings([
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
        try await withMeisterApp { app in
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
            try await app.meisterStore.insertJob(parent)
            try await app.meisterStore.replaceJobFiles([
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
        try await withMeisterApp { app in
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
            try await app.meisterStore.insertJob(parent)
            try await app.meisterStore.replaceJobFiles([
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
        try await withMeisterApp { app in
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
            try await app.meisterStore.insertJob(parent)
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
        try await withMeisterApp { app in
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
        try await withMeisterApp(mutate: { $0.limits.archiveBytes = 8 }) { app in
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
        try await withMeisterApp(mutate: { $0.limits.queuedArchiveBytes = 8 }) { app in
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
        try await withMeisterApp { app in
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
        try await withMeisterApp(docker: docker) { app in
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
            try await app.meisterStore.insertJob(job)
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
        try await withMeisterApp { app in
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
            try await app.meisterStore.insertJob(job)
            try await app.testing().test(.POST, "/api/jobs/\(job.id.rawValue)/cancel") {
                res async throws in
                #expect(res.status == .conflict)
                try assertError(res, code: "conflict")
            }
        }
    }

    @Test
    func listAndDetailEncodeNullsAndNoExtraKeys() async throws {
        try await withMeisterApp { app in
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
            try await app.meisterStore.insertJob(job)
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
    func skipAgentPipelineReachesSucceeded() async throws {
        try await withMeisterApp(startQueue: true) { app in
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
        }
    }

    @Test
    func identifyFailureIsNoChangeSet() async throws {
        try await withMeisterApp(startQueue: true) { app in
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
}

private let jobListKeys: Set<String> = [
    "id", "title", "status", "scope", "parent_job_id",
    "reviewer_a_model_id", "reviewer_b_model_id", "judge_model_id",
    "base_sha", "head_sha", "queue_position", "summary",
    "created_at", "started_at", "finished_at", "error_message",
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
        .appendingPathComponent("meister-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "hi\n".write(to: dir.appendingPathComponent("README"), atomically: true, encoding: .utf8)
    let archive = FileManager.default.temporaryDirectory
        .appendingPathComponent("meister-empty-\(UUID().uuidString).tar.gz")
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

private func packedTinyRepo() throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = root.appendingPathComponent("scripts/pack-repo.sh")
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("meister-pack-\(UUID().uuidString)", isDirectory: true)
    let repo = dir.appendingPathComponent("tiny")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=meister",
            "-c", "user.email=meister@localhost",
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
    try "v1\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"])
    try git(["commit", "-m", "v1"])
    try "v2\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"])
    try git(["commit", "-m", "v2"])

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path, "HEAD^"]
    process.currentDirectoryURL = repo
    process.environment = [
        "PATH": "/usr/bin:/bin",
        "HOME": dir.appendingPathComponent("home").path,
        "GIT_CONFIG_NOSYSTEM": "1",
        "COPYFILE_DISABLE": "1",
    ]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw APIError.badRequest("pack-repo failed")
    }
    return stdout.fileHandleForReading.readDataToEndOfFile()
}
