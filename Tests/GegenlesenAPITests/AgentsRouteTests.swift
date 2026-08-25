import Foundation
import Testing
import Vapor
import VaporTesting
@testable import GegenlesenAPI

@Suite
struct AgentsRouteTests {
    @Test
    func listReturnsPackagedDefaults() async throws {
        try await withAgentsApp { app in
            try await app.testing().test(.GET, "/api/agents") { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(AgentListDTO.self)
                #expect(body.agents.map(\.id) == AgentCatalog.ids)
                #expect(body.minerModel == "openrouter/openai/gpt-5.6-terra")
                for agent in body.agents {
                    #expect(!agent.customized)
                    #expect(!agent.prompt.isEmpty)
                    #expect(!agent.description.isEmpty)
                }
                let reviewer = try #require(body.agents.first { $0.id == "reviewer" })
                #expect(reviewer.prompt.contains(".gegenlesen/findings.json"))
                for agent in body.agents {
                    #expect(!agent.requiredPaths.isEmpty)
                    #expect(AgentCatalog.missingPaths(id: agent.id, prompt: agent.prompt).isEmpty)
                }
            }
        }
    }

    @Test
    func getUnknownIsNotFound() async throws {
        try await withAgentsApp { app in
            try await app.testing().test(.GET, "/api/agents/build") { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test
    func putPersistsAndResetRestores() async throws {
        try await withAgentsApp { app in
            let original = try await getAgent(app, id: "reviewer")
            try await app.testing().test(
                .PUT,
                "/api/agents/reviewer",
                beforeRequest: { req async throws in
                    try req.content.encode(AgentUpdate(prompt: original.prompt + "\ncustom body\n"))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(AgentDTO.self)
                #expect(body.customized)
                #expect(body.prompt.contains("custom body"))
                #expect(AgentCatalog.missingPaths(id: "reviewer", prompt: body.prompt).isEmpty)
            }
            let saved = try await getAgent(app, id: "reviewer")
            #expect(saved.customized)
            try await app.testing().test(.POST, "/api/agents/reviewer/reset") { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(AgentDTO.self)
                #expect(!body.customized)
                #expect(body.prompt == original.prompt)
            }
        }
    }

    @Test
    func putRejectsMissingRequiredPaths() async throws {
        try await withAgentsApp { app in
            try await app.testing().test(
                .PUT,
                "/api/agents/reviewer",
                beforeRequest: { req async throws in
                    try req.content.encode(AgentUpdate(prompt: "---\ndescription: broken\nmode: primary\ntemperature: 0.2\n---\n\nno workspace files\n"))
                }
            ) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("missing required paths"))
                #expect(res.body.string.contains("findings-model_a.json"))
            }
            let saved = try await getAgent(app, id: "reviewer")
            #expect(!saved.customized)
        }
    }

    @Test
    func putRejectsBlankPrompt() async throws {
        try await withAgentsApp { app in
            try await app.testing().test(
                .PUT,
                "/api/agents/judge",
                beforeRequest: { req async throws in
                    try req.content.encode(AgentUpdate(prompt: "   \n"))
                }
            ) { res async in
                #expect(res.status == .unprocessableEntity)
            }
        }
    }

    @Test
    func improveUsesDraftAndMinerModel() async throws {
        let fake = RecordingPromptImprover()
        try await withAgentsApp(promptImprover: fake) { app in
            let miner = try await getAgent(app, id: "miner")
            try await app.testing().test(
                .POST,
                "/api/agents/miner/improve",
                beforeRequest: { req async throws in
                    try req.content.encode(AgentImproveRequest(
                        instruction: "be shorter",
                        prompt: miner.prompt
                    ))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(AgentImproveResponse.self)
                #expect(body.prompt.contains("IMPROVED:"))
                #expect(body.prompt.contains("be shorter"))
                #expect(AgentCatalog.missingPaths(id: "miner", prompt: body.prompt).isEmpty)
            }
            #expect(fake.model == "openrouter/openai/gpt-5.6-terra")
            #expect(fake.currentPrompt == miner.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(fake.instruction?.contains("be shorter") == true)
            #expect(fake.instruction?.contains("mined-rules.json") == true)
            let listed = try await getAgent(app, id: "miner")
            #expect(!listed.customized)
            #expect(!listed.prompt.contains("IMPROVED:"))
        }
    }

    @Test
    func improveRejectsMissingRequiredPaths() async throws {
        let fake = RecordingPromptImprover()
        fake.result = "---\ndescription: miner\nmode: primary\ntemperature: 0.2\n---\n\nno output path\n"
        try await withAgentsApp(promptImprover: fake) { app in
            try await app.testing().test(
                .POST,
                "/api/agents/miner/improve",
                beforeRequest: { req async throws in
                    try req.content.encode(AgentImproveRequest(instruction: "rewrite", prompt: nil))
                }
            ) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("missing required paths"))
                #expect(res.body.string.contains("mined-rules.json"))
            }
            let listed = try await getAgent(app, id: "miner")
            #expect(!listed.customized)
        }
    }

    @Test
    func improveRequiresInstruction() async throws {
        try await withAgentsApp { app in
            try await app.testing().test(
                .POST,
                "/api/agents/judge/improve",
                beforeRequest: { req async throws in
                    try req.content.encode(AgentImproveRequest(instruction: "  ", prompt: nil))
                }
            ) { res async in
                #expect(res.status == .unprocessableEntity)
            }
        }
    }

    @Test
    func improveDisabledWhenSkipAgentAndNoImprover() async throws {
        try await withAgentsApp(promptImprover: nil) { app in
            try await app.testing().test(
                .POST,
                "/api/agents/reviewer/improve",
                beforeRequest: { req async throws in
                    try req.content.encode(AgentImproveRequest(instruction: "tighten", prompt: nil))
                }
            ) { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("skip-agent"))
            }
        }
    }

    @Test
    func unwrapAndModelID() {
        #expect(OpenRouterChat.openRouterModelID("openrouter/openai/gpt-5.6-terra") == "openai/gpt-5.6-terra")
        #expect(OpenRouterChat.openRouterModelID("openai/gpt-5.6-terra") == "openai/gpt-5.6-terra")
        #expect(OpenRouterChat.unwrap("```markdown\nhello\n```") == "hello")
        #expect(OpenRouterChat.unwrap("plain") == "plain")
    }

    @Test
    func missingPathsDetectsDroppedWrites() {
        #expect(AgentCatalog.missingPaths(id: "reviewer", prompt: "no files").contains(".gegenlesen/findings-model_a.json"))
        #expect(AgentCatalog.missingPaths(id: "judge", prompt: "Write .gegenlesen/judge.json").contains(".gegenlesen/judge-input.json"))
        #expect(AgentCatalog.missingPaths(id: "miner", prompt: "Write `.gegenlesen/mined-rules.json` only.").isEmpty)
    }
}

private let packagedRoot: String = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<8 {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url.path
        }
    }
    return FileManager.default.currentDirectoryPath
}()

private func withAgentsApp(
    promptImprover: (any PromptImproving)? = FakePromptImprover(),
    _ body: (Application) async throws -> Void
) async throws {
    try await withGegenlesenApp(
        workingDirectory: packagedRoot,
        promptImprover: promptImprover,
        body
    )
}

private func getAgent(_ app: Application, id: String) async throws -> AgentDTO {
    var decoded: AgentDTO?
    try await app.testing().test(.GET, "/api/agents/\(id)") { res async throws in
        #expect(res.status == .ok)
        decoded = try res.content.decode(AgentDTO.self)
    }
    return try #require(decoded)
}

private final class RecordingPromptImprover: PromptImproving, @unchecked Sendable {
    var model: String?
    var currentPrompt: String?
    var instruction: String?
    var result: String?

    func improve(model: String, currentPrompt: String, instruction: String) async throws -> String {
        self.model = model
        self.currentPrompt = currentPrompt
        self.instruction = instruction
        if let result { return result }
        return currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\nIMPROVED:\n\(instruction)\n"
    }
}
