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
        let edit = try #require(permission["edit"] as? [String: String])
        #expect(edit["*"] == "deny")
        #expect(edit[".gegenlesen/findings.json"] == "allow")
        #expect(edit[".gegenlesen/findings-model_a.json"] == "allow")
        #expect(edit[".gegenlesen/findings-model_b.json"] == "allow")
        #expect(edit["*/.gegenlesen/findings-model_a.json"] == "allow")
        #expect(edit["*/.gegenlesen/findings-model_b.json"] == "allow")
        #expect(edit["*/.gegenlesen/judge.json"] == "allow")
        #expect(edit["*/.gegenlesen/suggestion-judge.json"] == "allow")
        #expect(edit[".gegenlesen/harvest.json"] == "allow")
        #expect(edit["*/.gegenlesen/harvest.json"] == "allow")
        let agents = try #require(object["agent"] as? [String: Any])
        #expect(agents["suggestion-judge"] != nil)
        #expect(agents["harvester"] != nil)
        #expect(edit.keys.contains { $0.hasPrefix("Sources") } == false)

        let bash = try #require(permission["bash"] as? [String: String])
        #expect(bash["*"] == "deny")
        #expect(bash["git diff*"] == "allow")
        #expect(bash["rg *"] == "allow")
        #expect(bash["curl *"] == nil)

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
        let edit = try #require(permission["edit"] as? [String: String])
        #expect(edit["*"] == "deny")
        #expect(edit[".gegenlesen/findings.json"] == "allow")
        #expect(edit[".gegenlesen/suggestion-judge.json"] == "allow")
        let agents = try #require(object["agent"] as? [String: Any])
        #expect(agents["suggestion-judge"] != nil)
        #expect(edit["*/.gegenlesen/findings-model_a.json"] == "allow")
        #expect(edit.keys.contains { $0.hasPrefix("Sources") } == false)
    }
}
