import Foundation
import Testing
import VaporTesting
@testable import MeisterAPI
@testable import MeisterCore

@Suite
struct RulesRouteTests {
    @Test
    func crudAndSoftDelete() async throws {
        try await withMeisterApp { app in
            let created = try await request(
                app,
                .POST,
                "/api/rules",
                json: """
                {
                  "id": "ban-print",
                  "title": "Ban print",
                  "severity": "warning",
                  "kind": "semantic",
                  "languages": ["swift"],
                  "path_globs": ["**/*.swift"],
                  "payload": { "instruction": "Do not use print()", "few_shots": [] },
                  "body": "house style"
                }
                """
            )
            #expect(created.status == .created)
            let object = try jsonObject(created)
            #expect(Set(object.keys) == ruleKeys)
            #expect(object["body"] as? String == "house style")
            #expect(object["id"] as? String == "ban-print")
            #expect(object["deleted_at"] is NSNull)

            try await app.testing().test(.GET, "/api/rules?kind=semantic") { res async throws in
                #expect(res.status == .ok)
                let body = try jsonObject(res)
                #expect(Set(body.keys) == ["rules"])
                let rules = try #require(body["rules"] as? [[String: Any]])
                #expect(rules.contains { $0["id"] as? String == "ban-print" })
            }

            let updated = try await request(
                app,
                .PUT,
                "/api/rules/ban-print",
                json: """
                {
                  "title": "Ban print still",
                  "severity": "error",
                  "kind": "semantic",
                  "languages": ["swift"],
                  "path_globs": ["**/*.swift"],
                  "payload": { "instruction": "Still no print" }
                }
                """
            )
            #expect(updated.status == .ok)
            #expect(try jsonObject(updated)["severity"] as? String == "error")

            try await app.testing().test(.POST, "/api/rules/ban-print/disable") { res async throws in
                #expect(res.status == .ok)
                #expect(try jsonObject(res)["enabled"] as? Bool == false)
            }
            try await app.testing().test(.POST, "/api/rules/ban-print/enable") { res async throws in
                #expect(try jsonObject(res)["enabled"] as? Bool == true)
            }

            try await app.testing().test(.DELETE, "/api/rules/ban-print") { res async throws in
                #expect(res.status == .ok)
                #expect(!(try jsonObject(res)["deleted_at"] is NSNull))
            }
            try await app.testing().test(.GET, "/api/rules") { res async throws in
                let body = try jsonObject(res)
                let rules = try #require(body["rules"] as? [[String: Any]])
                #expect(!rules.contains { $0["id"] as? String == "ban-print" })
            }
        }
    }

    @Test
    func promoteHandwrittenConflicts() async throws {
        try await withMeisterApp { app in
            let now = Date()
            try await app.meisterStore.insertRule(
                Rule(
                    id: RuleID("mined-eval"),
                    title: "Ban eval",
                    severity: .error,
                    kind: .deterministic,
                    enabled: false,
                    provenance: .mined,
                    languages: ["javascript"],
                    pathGlobs: ["**/*.js"],
                    payload: .denyAPI(symbols: ["eval"], message: "no"),
                    createdAt: now,
                    updatedAt: now
                )
            )
            try await app.testing().test(.POST, "/api/rules/mined-eval/promote") { res async throws in
                #expect(res.status == .created)
                let body = try jsonObject(res)
                #expect(Set(body.keys) == ruleKeys)
                #expect(body["provenance"] as? String == "handwritten")
                #expect(body["promoted_from_rule_id"] as? String == "mined-eval")
                #expect(body["id"] as? String != "mined-eval")
            }
            try await app.testing().test(.POST, "/api/rules/mined-eval/promote") { res async throws in
                #expect(res.status == .created)
            }
            try await app.testing().test(.POST, "/api/rules/mined-eval-handwritten/promote") { res async throws in
                #expect(res.status == .conflict)
                let body = try jsonObject(res)
                let error = try #require(body["error"] as? [String: Any])
                #expect(error["code"] as? String == "conflict")
                #expect(Set(body.keys) == ["error"])
            }
        }
    }

    @Test
    func unknownRuleIsNotFound() async throws {
        try await withMeisterApp { app in
            try await app.testing().test(.GET, "/api/rules/missing-rule") { res async throws in
                #expect(res.status == .notFound)
                let body = try jsonObject(res)
                let error = try #require(body["error"] as? [String: Any])
                #expect(error["code"] as? String == "not_found")
            }
        }
    }

    @Test
    func bootSeedsDoNotRequireOverwrite() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try await withMeisterApp(workingDirectory: root.path) { app in
            try await app.testing().test(.GET, "/api/rules") { res async throws in
                let body = try jsonObject(res)
                let rules = try #require(body["rules"] as? [[String: Any]])
                let ids = Set(rules.compactMap { $0["id"] as? String })
                #expect(ids.contains("use-project-logger"))
                #expect(ids.contains("openapi-breaking-changes"))
                #expect(ids.contains("no-hardcoded-secrets"))
            }
        }
    }
}

private let ruleKeys: Set<String> = [
    "id", "title", "severity", "kind", "enabled", "deleted_at", "provenance",
    "languages", "path_globs", "payload", "examples", "source_pr_refs",
    "promoted_from_rule_id", "body", "created_at", "updated_at",
]

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