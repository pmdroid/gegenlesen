import Foundation
import Testing
import Vapor
import VaporTesting
@testable import GegenlesenAPI
@testable import GegenlesenCore

@Suite
struct HarvestRouteTests {
    @Test
    func missingArchiveIsBadRequest() async throws {
        try await withGegenlesenApp { app in
            try await app.testing().test(.POST, "/api/harvest") { res async throws in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test
    func skipAgentHarvestSucceeds() async throws {
        try await withGegenlesenApp(startQueue: true) { app in
            let archive = try harvestTarGz()
            var captured: TestingHTTPResponse?
            try await app.testing().test(
                .POST,
                "/api/harvest",
                beforeRequest: { req in
                    try req.content.encode(
                        HarvestPostBody(
                            archive: File(data: .init(data: archive), filename: "tree.tar.gz")
                        ),
                        as: .formData
                    )
                },
                afterResponse: { res async in
                    captured = res
                }
            )
            let res = try #require(captured)
            #expect(res.status == .accepted)
            let accepted = try JSONDecoder().decode(JobAccepted.self, from: Data(res.body.readableBytesView))

            let deadline = Date().addingTimeInterval(10)
            var job: Job?
            while Date() < deadline {
                job = try await app.gegenlesenStore.job(id: accepted.id)
                if job?.status.isTerminal == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(job?.status == .succeeded)
            let learnings = try await app.gegenlesenStore.listLearnings(status: .pending)
            #expect(learnings.contains { $0.payloadJSON?.contains("harvest") == true })
        }
    }

    @Test
    func harvestSnapshotsSlotEngines() async throws {
        try await withGegenlesenApp(mutate: { config in
            config.openrouterApiKey = "sk-or-test"
            config.models.engineA = "claude"
            config.models.engineB = "codex"
            config.judgeEngine = "claude"
        }) { app in
            let archive = try harvestTarGz()
            var captured: TestingHTTPResponse?
            try await app.testing().test(
                .POST,
                "/api/harvest",
                beforeRequest: { req in
                    try req.content.encode(
                        HarvestPostBody(
                            archive: File(data: .init(data: archive), filename: "tree.tar.gz")
                        ),
                        as: .formData
                    )
                },
                afterResponse: { res async in
                    captured = res
                }
            )
            let res = try #require(captured)
            #expect(res.status == .accepted)
            let accepted = try JSONDecoder().decode(JobAccepted.self, from: Data(res.body.readableBytesView))
            let stored = try #require(try await app.gegenlesenStore.job(id: accepted.id))
            #expect(stored.reviewerAEngine == "claude")
            #expect(stored.reviewerBEngine == "codex")
            #expect(stored.judgeEngine == "claude")
        }
    }

    @Test
    func ingestMissingJobIsNotFound() async throws {
        try await withGegenlesenApp { app in
            try await app.testing().test(
                .POST,
                "/api/harvest/00000000-0000-4000-8000-000000000000/ingest"
            ) { res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test
    func ingestMissingHarvestFileIsUnprocessable() async throws {
        try await withGegenlesenApp { app in
            let jobID = JobID("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
            try await app.gegenlesenStore.insertJob(harvestJob(id: jobID, status: .failed))
            try await app.testing().test(
                .POST,
                "/api/jobs/\(jobID.rawValue)/harvest/ingest"
            ) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("no harvest.json"))
            }
        }
    }

    @Test
    func ingestExistingHarvestPersistsDisabledRules() async throws {
        try await withGegenlesenApp { app in
            let jobID = JobID("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")
            try await app.gegenlesenStore.insertJob(harvestJob(id: jobID, status: .failed))
            let dir = app.gegenlesenStore.blobs.workspaceURL(jobID: jobID.rawValue)
                .appendingPathComponent(".gegenlesen", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try """
            {
              "rules": [{
                "title": "Never print in payment code",
                "severity": "high",
                "kind": "semantic",
                "instruction": "Never print in payment code.",
                "body": "Never print in payment code.",
                "evidence": [{"path": "Sources/Pay.swift", "excerpt": "Logger.shared"}]
              }],
              "notes": [{
                "title": "CI is optional",
                "body": "Guest boot is not a required check.",
                "evidence": [{"path": "docs/ci.md", "excerpt": "never a required status check"}]
              }]
            }
            """.write(
                to: dir.appendingPathComponent("harvest.json"),
                atomically: true,
                encoding: .utf8
            )
            try await app.testing().test(
                .POST,
                "/api/harvest/\(jobID.rawValue)/ingest"
            ) { res async throws in
                #expect(res.status == .ok)
                let body = try JSONDecoder().decode(HarvestIngestResponse.self, from: Data(res.body.readableBytesView))
                #expect(body.rules == 1)
                #expect(body.notes == 1)
            }
            let rules = try await app.gegenlesenStore.listRules(RuleListFilter(includeDeleted: true))
            let harvest = rules.filter { $0.provenance == .harvest }
            #expect(harvest.count == 1)
            #expect(harvest[0].enabled == false)
            #expect(harvest[0].severity == .error)
        }
    }
}

private struct HarvestPostBody: Content {
    var archive: File
}

private func harvestJob(id: JobID, status: JobStatus) -> Job {
    let now = Date()
    return Job(
        id: id,
        createdAt: now,
        updatedAt: now,
        status: status,
        scope: .full,
        title: "harvest leftover",
        reviewerAModelID: "a",
        reviewerBModelID: "b",
        judgeModelID: "j"
    )
}

private func harvestTarGz() throws -> Data {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gegenlesen-harvest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "Do not commit secrets.\n".write(
        to: dir.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
    )
    let archive = FileManager.default.temporaryDirectory
        .appendingPathComponent("gegenlesen-harvest-\(UUID().uuidString).tar.gz")
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
