import Foundation
import Testing
import VaporTesting
@testable import MeisterAPI
@testable import MeisterCore

@Suite
struct CorpusRouteTests {
    @Test
    func ingestPairAndGetItem() async throws {
        try await withMeisterApp { app in
            let patch = Data("diff --git a/A.swift b/A.swift\n".utf8)
            let json = Data(#"{"title":"Ban the widget","body":"do not widget","comments":[{"body":"nit"}]}"#.utf8)
            let res = try await postCorpus(
                app,
                files: [
                    ("pr-42.patch", patch),
                    ("pr-42.json", json),
                ]
            )
            #expect(res.status == .accepted)
            let accepted = try JSONDecoder().decode(CorpusAccepted.self, from: bodyData(res))
            #expect(accepted.accepted == 1)

            try await app.testing().test(.GET, "/api/corpus") { response async throws in
                #expect(response.status == .ok)
                let object = try jsonObject(response)
                #expect(Set(object.keys) == ["items"])
                let items = try #require(object["items"] as? [[String: Any]])
                #expect(items.count == 1)
                #expect(items[0]["source_label"] as? String == "pr-42")
                #expect(items[0]["title"] as? String == "Ban the widget")
                #expect(items[0]["body"] as? String == "do not widget")
                let id = try #require(items[0]["id"] as? String)
                try await app.testing().test(.GET, "/api/corpus/\(id)") { detail async throws in
                    #expect(detail.status == .ok)
                    #expect(try jsonObject(detail)["source_label"] as? String == "pr-42")
                }
            }
        }
    }

    @Test
    func ingestTarGz() async throws {
        try await withMeisterApp { app in
            let archive = try corpusTarGz()
            let res = try await postCorpus(app, files: [("hist.tar.gz", archive)])
            #expect(res.status == .accepted)
            let accepted = try JSONDecoder().decode(CorpusAccepted.self, from: bodyData(res))
            #expect(accepted.accepted == 1)
        }
    }

    @Test
    func unknownCorpusItemIsNotFound() async throws {
        try await withMeisterApp { app in
            try await app.testing().test(.GET, "/api/corpus/11111111-1111-4111-8111-111111111111") {
                res async throws in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test
    func skipAgentMineProducesDisabledRulesAndDedups() async throws {
        try await withMeisterApp(startQueue: true) { app in
            let first = try await postCorpus(
                app,
                files: [
                    ("pr-a.patch", Data("diff\n".utf8)),
                    ("pr-a.json", Data(#"{"title":"Corpus unique widget ban"}"#.utf8)),
                ]
            )
            #expect(first.status == .accepted)

            let mined = try await postMine(app, body: "{}")
            #expect(mined.status == .accepted)
            let accepted = try JSONDecoder().decode(MineAccepted.self, from: bodyData(mined))
            try await waitSucceeded(app, jobID: accepted.jobID)

            let afterFirst = try await minedWidgetRules(app)
            #expect(afterFirst.count == 1)
            #expect(afterFirst[0]["enabled"] as? Bool == false)
            #expect(afterFirst[0]["provenance"] as? String == "mined")

            let second = try await postCorpus(
                app,
                files: [
                    ("pr-b.patch", Data("diff2\n".utf8)),
                    ("pr-b.json", Data(#"{"title":"Corpus unique widget ban"}"#.utf8)),
                ]
            )
            #expect(second.status == .accepted)
            let minedAgain = try await postMine(app, body: "{}")
            let acceptedAgain = try JSONDecoder().decode(MineAccepted.self, from: bodyData(minedAgain))
            try await waitSucceeded(app, jobID: acceptedAgain.jobID)

            let afterSecond = try await minedWidgetRules(app)
            #expect(afterSecond.count == 1)
            let refs = afterSecond[0]["source_pr_refs"] as? [String] ?? []
            #expect(refs.contains("pr-a"))
            #expect(refs.contains("pr-b"))
        }
    }

    @Test
    func learnEnqueuesMinerAndSkipAgentDoesNotFail() async throws {
        try await withMeisterApp(startQueue: true) { app in
            let now = Date()
            let job = Job(
                id: JobID("11111111-1111-4111-8111-111111111111"),
                createdAt: now,
                updatedAt: now,
                status: .succeeded,
                scope: .full,
                title: "Learn unique finding title",
                reviewerAModelID: "a",
                reviewerBModelID: "b",
                judgeModelID: "j"
            )
            try await app.meisterStore.insertJob(job)
            try await app.meisterStore.insertFindings(
                [
                    FindingDraft(
                        ruleID: nil,
                        phase: .agent,
                        severity: .warning,
                        title: "Learn unique finding title",
                        message: "do not do that",
                        filePath: "Sources/A.swift",
                        startLine: 1,
                        endLine: 1,
                        snippet: "let x = 1"
                    ),
                ],
                jobID: job.id,
                now: now
            )

            var captured: TestingHTTPResponse?
            try await app.testing().test(.POST, "/api/jobs/\(job.id.rawValue)/learn") { res async in
                captured = res
            }
            let res = try #require(captured)
            #expect(res.status == .accepted)
            let accepted = try JSONDecoder().decode(MineAccepted.self, from: bodyData(res))
            try await waitSucceeded(app, jobID: accepted.jobID)

            try await app.testing().test(.GET, "/api/rules?provenance=suggested") { response async throws in
                let body = try jsonObject(response)
                let rules = try #require(body["rules"] as? [[String: Any]])
                #expect(rules.contains { ($0["title"] as? String) == "Learn unique finding title" })
                let match = rules.first { ($0["title"] as? String) == "Learn unique finding title" }
                #expect(match?["enabled"] as? Bool == false)
            }
        }
    }
}

private func minedWidgetRules(_ app: Application) async throws -> [[String: Any]] {
    var rules: [[String: Any]] = []
    try await app.testing().test(.GET, "/api/rules?provenance=mined") { res async throws in
        let body = try jsonObject(res)
        rules = try #require(body["rules"] as? [[String: Any]])
            .filter { ($0["title"] as? String) == "Corpus unique widget ban" }
    }
    return rules
}

private func waitSucceeded(_ app: Application, jobID: JobID) async throws {
    let deadline = Date().addingTimeInterval(20)
    var status = JobStatus.queued
    var error: String?
    while Date() < deadline {
        try await app.testing().test(.GET, "/api/jobs/\(jobID.rawValue)") { res async throws in
            let object = try jsonObject(res)
            status = JobStatus(rawValue: object["status"] as? String ?? "") ?? .queued
            error = object["error_message"] as? String
        }
        if status.isTerminal { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(status == .succeeded, "ended \(status.rawValue) \(error ?? "")")
}

private func postMine(_ app: Application, body: String) async throws -> TestingHTTPResponse {
    var captured: TestingHTTPResponse?
    try await app.testing().test(
        .POST,
        "/api/corpus/mine",
        beforeRequest: { req in
            req.headers.contentType = .json
            req.body = .init(data: Data(body.utf8))
        },
        afterResponse: { res async in
            captured = res
        }
    )
    return try #require(captured)
}

private func postCorpus(
    _ app: Application,
    files: [(String, Data)]
) async throws -> TestingHTTPResponse {
    var captured: TestingHTTPResponse?
    try await app.testing().test(
        .POST,
        "/api/corpus",
        beforeRequest: { req in
            try req.content.encode(
                CorpusPostBody(item: files.map { File(data: .init(data: $0.1), filename: $0.0) }),
                as: .formData
            )
        },
        afterResponse: { res async in
            captured = res
        }
    )
    return try #require(captured)
}

private struct CorpusPostBody: Content {
    var item: [File]
}

private func bodyData(_ res: TestingHTTPResponse) -> Data {
    Data(res.body.readableBytesView)
}

private func jsonObject(_ res: TestingHTTPResponse) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: bodyData(res))
    return try #require(object as? [String: Any])
}

private func corpusTarGz() throws -> Data {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("meister-corpus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "diff --git a/x b/x\n".write(to: dir.appendingPathComponent("item.patch"), atomically: true, encoding: .utf8)
    try #"{"title":"from tar","body":"ok"}"#.write(
        to: dir.appendingPathComponent("item.json"),
        atomically: true,
        encoding: .utf8
    )
    let archive = FileManager.default.temporaryDirectory
        .appendingPathComponent("meister-corpus-\(UUID().uuidString).tar.gz")
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
