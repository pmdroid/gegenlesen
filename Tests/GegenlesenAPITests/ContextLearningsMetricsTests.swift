import Foundation
import Testing
import VaporTesting
@testable import GegenlesenAPI
@testable import GegenlesenCore

@Suite
struct ContextLearningsMetricsTests {
    @Test
    func embeddingTargetStripsOpenAIPrefix() {
        let target = EmbeddingClientFactory.resolveTarget(
            model: "openai/text-embedding-3-small",
            environment: ["OPENAI_API_KEY": "sk-test"]
        )
        #expect(target?.model == "text-embedding-3-small")
        #expect(target?.endpoint == EmbeddingClientFactory.openAIEndpoint)
    }

    @Test
    func metricsReportsQueueDepth() async throws {
        try await withGegenlesenApp { app in
            let now = Date()
            try await app.gegenlesenStore.insertJob(
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
                #expect(res.headers.contentType?.subType == "plain" || res.body.string.contains("gegenlesen_queue_depth"))
                #expect(res.body.string.contains("gegenlesen_queue_depth 1"))
                #expect(res.body.string.contains("gegenlesen_archive_bytes 42"))
            }
            #expect(MetricsRoute.isLoopbackAddress(nil))
            #expect(MetricsRoute.isLoopbackAddress("127.0.0.1"))
            #expect(MetricsRoute.isLoopbackAddress("::1"))
            #expect(MetricsRoute.isLoopbackAddress("::ffff:127.0.0.1"))
            #expect(!MetricsRoute.isLoopbackAddress("8.8.8.8"))
        }
    }

    @Test
    func contextCRUDAndLearningsInbox() async throws {
        try await withGegenlesenApp { app in
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
            try await app.gegenlesenStore.insertLearning(learning)

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
            try await app.gegenlesenStore.insertLearning(other)
            try await app.testing().test(.POST, "/api/learnings/\(other.id)/dismiss") { res async throws in
                let dismissed = try jsonObject(res)
                #expect(dismissed["status"] as? String == "dismissed")
                #expect(dismissed["dismiss_reason"] as? String == nil)
            }

            let tagged = Learning(
                kind: .rule,
                title: "Use the project logger",
                body: "no print",
                payloadJSON: #"{"rule_id":"use-project-logger","source":"harvest"}"#
            )
            try await app.gegenlesenStore.insertLearning(tagged)
            try await app.testing().test(
                .POST,
                "/api/learnings/\(tagged.id)/dismiss",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(data: Data(#"{"reason":"already_covered","comment":"house logger rule exists"}"#.utf8))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try jsonObject(res)
                    #expect(body["status"] as? String == "dismissed")
                    #expect(body["dismiss_reason"] as? String == "already_covered")
                    #expect(body["dismiss_comment"] as? String == "house logger rule exists")
                }
            )
            let stored = try #require(try await app.gegenlesenStore.learning(id: tagged.id))
            #expect(stored.status == .dismissed)
            #expect(stored.dismissReason == .alreadyCovered)
            #expect(stored.dismissComment == "house logger rule exists")
            #expect(stored.payloadString("rule_id") == "use-project-logger")
            #expect(stored.payloadString("source") == "harvest")

            let bogus = Learning(kind: .context, title: "Skip", body: "x")
            try await app.gegenlesenStore.insertLearning(bogus)
            try await app.testing().test(
                .POST,
                "/api/learnings/\(bogus.id)/dismiss",
                beforeRequest: { req in
                    req.headers.contentType = .json
                    req.body = .init(data: Data(#"{"reason":"not_a_real_reason"}"#.utf8))
                },
                afterResponse: { res async throws in
                    #expect(res.status == .badRequest)
                    let object = try jsonObject(res)
                    let error = try #require(object["error"] as? [String: Any])
                    #expect(error["code"] as? String == "bad_request")
                }
            )
            #expect(try await app.gegenlesenStore.learning(id: bogus.id)?.status == .pending)

            try await app.testing().test(.GET, "/api/learnings?status=pending") { res async throws in
                let body = try jsonObject(res)
                let yield = try #require(body["yield"] as? [[String: Any]])
                let rule = try #require(yield.first { $0["kind"] as? String == "rule" })
                #expect((rule["accepted"] as? NSNumber)?.intValue == 0)
                #expect((rule["dismissed"] as? NSNumber)?.intValue == 1)
                #expect((rule["rate"] as? NSNumber)?.doubleValue == 0)
                let context = try #require(yield.first { $0["kind"] as? String == "context" })
                #expect((context["accepted"] as? NSNumber)?.intValue == 1)
                #expect((context["dismissed"] as? NSNumber)?.intValue == 0)
                #expect((context["rate"] as? NSNumber)?.doubleValue == 1)
                let architecture = try #require(yield.first { $0["kind"] as? String == "architecture" })
                #expect((architecture["dismissed"] as? NSNumber)?.intValue == 1)
            }

            try await app.testing().test(.POST, "/api/learnings/\(tagged.id)/restore") { res async throws in
                #expect(res.status == .ok)
                let body = try jsonObject(res)
                #expect(body["status"] as? String == "pending")
                #expect(body["dismiss_reason"] as? String == nil)
            }
            let restored = try #require(try await app.gegenlesenStore.learning(id: tagged.id))
            #expect(restored.status == .pending)
            #expect(restored.dismissReason == nil)
            #expect(restored.resolvedAt == nil)
            #expect(restored.payloadString("rule_id") == "use-project-logger")

            try await app.testing().test(.POST, "/api/learnings/\(learning.id)/restore") { res async throws in
                #expect(res.status == .conflict)
            }
        }
    }
}

private func jsonObject(_ res: TestingHTTPResponse) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
    return try #require(object as? [String: Any])
}
