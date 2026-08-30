import Foundation
import GegenlesenCore
import Testing
import VaporTesting
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
    func emptyEngineStringDefaultsToOpencode() throws {
        let json = """
        {
          "bind": "127.0.0.1",
          "port": 8080,
          "data_dir": "var",
          "models": {
            "engine_a": "",
            "model_a": "openrouter/a",
            "engine_b": "codex",
            "model_b": "openrouter/b"
          },
          "judge_engine": "",
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
        #expect(config.models.engineB == "codex")
        #expect(config.judgeEngine == AgentEngineID.opencode)
    }

    @Test
    func legacyConfigWithoutEngineKeysPersistsOpencodeOnUnrelatedPut() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gegenlesen-legacy-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("gegenlesen.json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let legacy = """
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
          "openrouter_api_key": "sk-or-test",
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
        try legacy.write(to: file, atomically: true, encoding: .utf8)
        let loaded = try JSONDecoder().decode(GegenlesenConfig.self, from: Data(contentsOf: file))

        try await withGegenlesenApp(configFileURL: file, mutate: { config in
            config.bind = loaded.bind
            config.port = loaded.port
            config.dataDir = loaded.dataDir
            config.models = loaded.models
            config.judgeModel = loaded.judgeModel
            config.opencodeImage = loaded.opencodeImage
            config.limits = loaded.limits
            config.openrouterApiKey = loaded.openrouterApiKey
        }) { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        limits: LimitsSettingsUpdate(learnIntervalMinutes: 15)
                    ))
                }
            ) { res async throws in
                #expect(res.status == .ok)
            }
            let saved = try String(contentsOf: file, encoding: .utf8)
            #expect(saved.contains("engine_a"))
            #expect(saved.contains("opencode"))
        }
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
