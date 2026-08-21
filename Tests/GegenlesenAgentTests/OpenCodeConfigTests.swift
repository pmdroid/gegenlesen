import Foundation
import Testing
@testable import GegenlesenAgent

@Suite
struct OpenCodeConfigTests {
    @Test
    func policySealsMcpAndPluginAndDeniesSources() throws {
        let json = try OpenCodeConfig.policyJSON(model: "anthropic/claude-sonnet-4-5")
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let mcp = try #require(object["mcp"] as? [String: Any])
        #expect(mcp.isEmpty)
        let plugin = try #require(object["plugin"] as? [Any])
        #expect(plugin.isEmpty)
        #expect(object["share"] as? String == "disabled")
        #expect(object["subagent_depth"] == nil)
        #expect(object["model"] as? String == "anthropic/claude-sonnet-4-5")

        let permission = try #require(object["permission"] as? [String: Any])
        #expect(permission["edit"] as? String == "allow")
        #expect(permission["bash"] as? String == "allow")
        #expect(permission["webfetch"] as? String == "allow")
        #expect(permission["lsp"] as? String == "allow")
        #expect(permission["question"] as? String == "deny")
        #expect(permission["task"] as? String == "deny")
        let agents = try #require(object["agent"] as? [String: Any])
        #expect(agents["suggestion-judge"] != nil)
        #expect(agents["harvester"] != nil)
        #expect(agents["plan"] as? [String: Any] != nil)
        let lsp = try #require(object["lsp"] as? [String: Any])
        #expect(lsp["typescript"] != nil)
        #expect(lsp["pyright"] != nil)

        let read = try #require(permission["read"] as? [String: String])
        #expect(read["*"] == "allow")
        #expect(read["*.env"] == "deny")
    }

    @Test
    func splitModelKeepsOpenRouterAuthorInModelID() {
        let split = OpenCodeConfig.splitModel("openrouter/deepseek/deepseek-v4-flash")
        #expect(split.providerID == "openrouter")
        #expect(split.modelID == "deepseek/deepseek-v4-flash")
        let gemini = OpenCodeConfig.splitModel("openrouter/google/gemini-3.7-flash")
        #expect(gemini.providerID == "openrouter")
        #expect(gemini.modelID == "google/gemini-3.7-flash")
        let terra = OpenCodeConfig.splitModel("openrouter/openai/gpt-5.6-terra")
        #expect(terra.providerID == "openrouter")
        #expect(terra.modelID == "openai/gpt-5.6-terra")
    }

    @Test
    func bakedImagePolicyMatchesSealedKeys() throws {
        let url = repoRootFromAgentTests()
            .appendingPathComponent("docker/opencode-runner/opencode.json")
        let data = try Data(contentsOf: url)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mcp = try #require(object["mcp"] as? [String: Any])
        #expect(mcp.isEmpty)
        let plugin = try #require(object["plugin"] as? [Any])
        #expect(plugin.isEmpty)
        let permission = try #require(object["permission"] as? [String: Any])
        #expect(permission["edit"] as? String == "allow")
        #expect(permission["bash"] as? String == "allow")
        #expect(permission["lsp"] as? String == "allow")
        #expect(permission["question"] as? String == "deny")
        #expect(permission["task"] as? String == "deny")
        let agents = try #require(object["agent"] as? [String: Any])
        #expect(agents["suggestion-judge"] != nil)
        let lsp = try #require(object["lsp"] as? [String: Any])
        #expect(lsp["typescript"] != nil)
    }
}
