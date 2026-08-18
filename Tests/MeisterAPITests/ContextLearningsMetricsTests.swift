import Foundation
import Testing
import VaporTesting
@testable import MeisterAPI
@testable import MeisterCore

@Suite
struct ContextLearningsMetricsTests {
    @Test
    func metricsReportsQueueDepth() async throws {
        try await withMeisterApp { app in
            let now = Date()
            try await app.meisterStore.insertJob(
                Job(
                    id: JobID.generate(),
                    createdAt: now,
                    updatedAt: now,
                    status: .queued,
                    scope: .full,
                    reviewerAModelID: "a",
                    reviewerBModelID: "b",
                    judgeModelID: "a",
                    archiveBytes: 42
                )
            )
            try await app.testing().test(.GET, "/api/metrics") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.subType == "plain" || res.body.string.contains("meister_queue_depth"))
                #expect(res.body.string.contains("meister_queue_depth 1"))
                #expect(res.body.string.contains("meister_archive_bytes 42"))
            }
        }
    }

    @Test
    func contextCRUDAndLearningsInbox() async throws {
        try await withMeisterApp { app in
            var created: TestingHTTPResponse?
            try await app.testing().test(
                .POST,
                "/api/context",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(data: Data(#"{"title":"House log","body":"use project logger","always_include":true}"#.utf8))
                },
                afterResponse: { res async in created = res }
            )
            let createdRes = try #require(created)
            #expect(createdRes.status == .created)
            let createdObj = try jsonObject(createdRes)
            let id = try #require(createdObj["id"] as? String)
            #expect(createdObj["title"] as? String == "House log")
            #expect(createdObj["always_include"] as? Bool == true)

            try await app.testing().test(.GET, "/api/context") { res async throws in
                #expect(res.status == .ok)
                let body = try jsonObject(res)
                let notes = try #require(body["notes"] as? [[String: Any]])
                #expect(notes.count == 1)
            }

            try await app.testing().test(
                .PUT,
                "/api/context/\(id)",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(data: Data(#"{"title":"House log","body":"updated","always_include":false}"#.utf8))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    #expect(try jsonObject(res)["body"] as? String == "updated")
                }
            )

            try await app.testing().test(.DELETE, "/api/context/\(id)") { res async in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, "/api/context") { res async throws in
                let notes = try #require(try jsonObject(res)["notes"] as? [[String: Any]])
                #expect(notes.isEmpty)
            }

            let learning = Learning(
                kind: .context,
                title: "From job",
                body: "promote this note"
            )
            try await app.meisterStore.insertLearning(learning)

            try await app.testing().test(.GET, "/api/learnings?status=pending") { res async throws in
                #expect(res.status == .ok)
                let items = try #require(try jsonObject(res)["learnings"] as? [[String: Any]])
                #expect(items.contains { $0["id"] as? String == learning.id })
            }

            try await app.testing().test(.POST, "/api/learnings/\(learning.id)/accept") { res async throws in
                #expect(res.status == .ok)
                #expect(try jsonObject(res)["status"] as? String == "accepted")
            }
            try await app.testing().test(.GET, "/api/context") { res async throws in
                let notes = try #require(try jsonObject(res)["notes"] as? [[String: Any]])
                #expect(notes.contains { $0["title"] as? String == "From job" })
            }

            let other = Learning(kind: .architecture, title: "Layers", body: "API over Core")
            try await app.meisterStore.insertLearning(other)
            try await app.testing().test(.POST, "/api/learnings/\(other.id)/dismiss") { res async throws in
                #expect(try jsonObject(res)["status"] as? String == "dismissed")
            }
        }
    }
}

private func jsonObject(_ res: TestingHTTPResponse) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
    return try #require(object as? [String: Any])
}
