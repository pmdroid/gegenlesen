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
}

private struct HarvestPostBody: Content {
    var archive: File
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
