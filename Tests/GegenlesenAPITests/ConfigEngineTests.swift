import Foundation
import GegenlesenCore
import Testing
@testable import GegenlesenAPI

@Suite
struct ConfigEngineTests {
    @Test
    func enginesDefaultToOpencodeWhenOmitted() throws {
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
          "opencode_image": "img",
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
        #expect(config.models.engineA == AgentEngineID.opencode)
        #expect(config.models.engineB == AgentEngineID.opencode)
        #expect(config.judgeEngine == AgentEngineID.opencode)
    }

    @Test
    func enginesRoundTripThroughConfigJSON() throws {
        var config = GegenlesenConfig.example
        config.models.engineA = "claude"
        config.models.engineB = "codex"
        config.judgeEngine = "claude"
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(GegenlesenConfig.self, from: data)
        #expect(decoded.models.engineA == "claude")
        #expect(decoded.models.engineB == "codex")
        #expect(decoded.judgeEngine == "claude")
    }

    @Test
    func envOverridesSlotEngines() {
        let config = GegenlesenConfig.example.applyingEnvironmentOverrides([
            "GEGENLESEN_ENGINE_A": "claude",
            "GEGENLESEN_ENGINE_B": "codex",
            "GEGENLESEN_JUDGE_ENGINE": "claude",
        ])
        #expect(config.models.engineA == "claude")
        #expect(config.models.engineB == "codex")
        #expect(config.judgeEngine == "claude")
        let untouched = GegenlesenConfig.example.applyingEnvironmentOverrides([
            "GEGENLESEN_ENGINE_A": "",
        ])
        #expect(untouched.models.engineA == AgentEngineID.opencode)
    }

    @Test
    func settingsDTOExposesSlotEngines() {
        var config = GegenlesenConfig.example
        config.models.engineA = "claude"
        config.judgeEngine = "codex"
        let dto = config.settingsDTO(environment: [:])
        #expect(dto.models.engineA == "claude")
        #expect(dto.models.engineB == AgentEngineID.opencode)
        #expect(dto.judgeEngine == "codex")
    }
}
