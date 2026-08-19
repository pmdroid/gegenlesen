import Foundation
import Testing
import VaporTesting
@testable import GegenlesenAPI
@testable import GegenlesenCore

@Suite
struct RepositoryScopeTests {
    @Test
    func jobsFilterByRepositoryAndQuery() async throws {
        try await withGegenlesenApp { app in
            let now = Date()
            try await app.gegenlesenStore.insertJob(
                Job(
                    id: JobID("11111111-1111-4111-8111-111111111111"),
                    createdAt: now,
                    updatedAt: now,
                    status: .succeeded,
                    scope: .full,
                    title: "meister review",
                    repository: "github.com/acme/meister",
                    reviewerAModelID: "a",
                    reviewerBModelID: "b",
                    judgeModelID: "j"
                )
            )
            try await app.gegenlesenStore.insertJob(
                Job(
                    id: JobID("22222222-2222-4222-8222-222222222222"),
                    createdAt: now.addingTimeInterval(1),
                    updatedAt: now.addingTimeInterval(1),
                    status: .failed,
                    scope: .full,
                    title: "other review",
                    repository: "github.com/acme/other",
                    reviewerAModelID: "a",
                    reviewerBModelID: "b",
                    judgeModelID: "j"
                )
            )

            try await app.testing().test(.GET, "/api/jobs?repository=github.com/acme/meister") { res async throws in
                #expect(res.status == .ok)
                let jobs = try #require(try jsonObject(res)["jobs"] as? [[String: Any]])
                #expect(jobs.count == 1)
                #expect(jobs.first?["title"] as? String == "meister review")
            }
            try await app.testing().test(.GET, "/api/jobs?q=other") { res async throws in
                let jobs = try #require(try jsonObject(res)["jobs"] as? [[String: Any]])
                #expect(jobs.count == 1)
                #expect(jobs.first?["title"] as? String == "other review")
            }
            try await app.testing().test(.GET, "/api/jobs?status=failed") { res async throws in
                let jobs = try #require(try jsonObject(res)["jobs"] as? [[String: Any]])
                #expect(jobs.count == 1)
                #expect(jobs.first?["status"] as? String == "failed")
            }
            try await app.testing().test(.GET, "/api/repositories") { res async throws in
                #expect(res.status == .ok)
                let names = try #require(try jsonObject(res)["repositories"] as? [String])
                #expect(names == ["github.com/acme/meister", "github.com/acme/other"])
            }
        }
    }

    @Test
    func rulesAndContextAreScoped() async throws {
        try await withGegenlesenApp { app in
            let createdRule = try await request(
                app,
                .POST,
                "/api/rules",
                json: """
                {
                  "id": "repo-logger",
                  "title": "Repo logger",
                  "severity": "warning",
                  "kind": "semantic",
                  "languages": ["*"],
                  "path_globs": ["**/*"],
                  "repository": "github.com/acme/meister",
                  "payload": { "instruction": "use the project logger" }
                }
                """
            )
            #expect(createdRule.status == .created)
            #expect(try jsonObject(createdRule)["repository"] as? String == "github.com/acme/meister")

            try await app.testing().test(.GET, "/api/rules?repository=github.com/acme/meister") { res async throws in
                let rules = try #require(try jsonObject(res)["rules"] as? [[String: Any]])
                #expect(rules.contains { $0["id"] as? String == "repo-logger" })
            }
            try await app.testing().test(.GET, "/api/rules?repository=global") { res async throws in
                let rules = try #require(try jsonObject(res)["rules"] as? [[String: Any]])
                #expect(!rules.contains { $0["id"] as? String == "repo-logger" })
            }

            var createdNote: TestingHTTPResponse?
            try await app.testing().test(
                .POST,
                "/api/context",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(data: Data(#"{"title":"Repo note","body":"only here","repository":"github.com/acme/meister"}"#.utf8))
                },
                afterResponse: { res async in createdNote = res }
            )
            #expect(try #require(createdNote).status == .created)

            try await app.testing().test(.GET, "/api/context?repository=github.com/acme/meister") { res async throws in
                let notes = try #require(try jsonObject(res)["notes"] as? [[String: Any]])
                #expect(notes.contains { $0["title"] as? String == "Repo note" })
            }
            try await app.testing().test(.GET, "/api/context?unscoped=true") { res async throws in
                let notes = try #require(try jsonObject(res)["notes"] as? [[String: Any]])
                #expect(!notes.contains { $0["title"] as? String == "Repo note" })
            }
        }
    }
}

private func request(
    _ app: Application,
    _ method: HTTPMethod,
    _ path: String,
    json: String
) async throws -> TestingHTTPResponse {
    var captured: TestingHTTPResponse?
    try await app.testing().test(
        method,
        path,
        beforeRequest: { req in
            req.headers.contentType = .json
            req.body = .init(data: Data(json.utf8))
        },
        afterResponse: { res async in
            captured = res
        }
    )
    return try #require(captured)
}

private func jsonObject(_ res: TestingHTTPResponse) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
    return try #require(object as? [String: Any])
}
