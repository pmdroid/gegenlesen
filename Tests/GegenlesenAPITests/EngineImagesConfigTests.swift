import Foundation
import GegenlesenCore
import Testing
@testable import GegenlesenAPI

@Suite
struct EngineImagesConfigTests {
    @Test
    func legacyConfigWithoutEngineImagesUsesOpencodeImageDefault() throws {
        let json = """
        {
          "bind": "127.0.0.1",
          "port": 8080,
          "data_dir": "var",
          "models": {
            "model_a": "openrouter/a",
            "model_b": "openrouter/b"
          },
          "judge_model": "openrouter/judge",
          "opencode_image": "custom/opencode:1.2.3",
          "limits": {
            "archive_bytes": 100,
            "queued_archive_bytes": 200,
            "agent_timeout_sec": 900,
            "judge_timeout_sec": 300,
            "deterministic_timeout_sec": 30,
            "identify_timeout_sec": 60,
            "rule_token_budget": 6000
          }
        }
        """
        let config = try JSONDecoder().decode(GegenlesenConfig.self, from: Data(json.utf8))
        #expect(config.engineImages.isEmpty)
        #expect(config.runnerImage(for: AgentEngineID.opencode) == "custom/opencode:1.2.3")
        #expect(config.runnerImage(for: AgentEngineID.claude) == GegenlesenConfig.defaultClaudeRunnerImage)
    }

    @Test
    func engineImagesMapOverridesDefaults() throws {
        var config = GegenlesenConfig.example
        config.engineImages = [
            AgentEngineID.claude: "registry.example/claude:9.9.9",
        ]
        #expect(config.runnerImage(for: AgentEngineID.claude) == "registry.example/claude:9.9.9")
        #expect(config.runnerImage(for: AgentEngineID.opencode) == config.opencodeImage)
    }

    @Test
    func claudeRunnerImageEnvOverride() {
        let config = GegenlesenConfig.example.applyingEnvironmentOverrides([
            "GEGENLESEN_CLAUDE_RUNNER_IMAGE": "local/claude:dev",
        ])
        #expect(config.runnerImage(for: AgentEngineID.claude) == "local/claude:dev")
    }
}
