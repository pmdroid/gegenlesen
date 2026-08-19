import Foundation
import Testing
import VaporTesting
@testable import GegenlesenAPI

@Suite
struct ModelsRouteTests {
    @Test
    func listUsesHeaderKeyAndFiltersCannedWhenSkipAgent() async throws {
        try await withGegenlesenApp { app in
            try await app.testing().test(
                .GET,
                "/api/models?q=terra&sort=coding-high-to-low&category=programming",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: "X-OpenRouter-Key", value: "sk-or-test")
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(OpenRouterModelList.self)
                #expect(body.models.count == 1)
                #expect(body.models[0].id == "openrouter/openai/gpt-5.6-terra")
                #expect(body.sort == "coding-high-to-low")
                #expect(body.category == "programming")
                #expect(!res.body.string.contains("sk-or-test"))
            }
        }
    }

    @Test
    func listFreeFiltersCanned() async throws {
        try await withGegenlesenApp { app in
            try await app.testing().test(
                .GET,
                "/api/models?free=true",
                beforeRequest: { req in
                    req.headers.replaceOrAdd(name: "X-OpenRouter-Key", value: "sk-or-test")
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(OpenRouterModelList.self)
                #expect(body.free)
                #expect(body.models.contains { $0.id.contains(":free") })
                for model in body.models {
                    #expect(model.free)
                }
            }
        }
    }
}
