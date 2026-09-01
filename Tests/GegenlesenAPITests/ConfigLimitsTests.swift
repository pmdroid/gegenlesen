import Foundation
import Testing
@testable import GegenlesenAPI

@Suite
struct ConfigLimitsTests {
    @Test
    func mineTimeoutDefaultsWhenOmitted() throws {
        let json = """
        {
          "archive_bytes": 100,
          "queued_archive_bytes": 200,
          "agent_timeout_sec": 900,
          "judge_timeout_sec": 300,
          "deterministic_timeout_sec": 30,
          "identify_timeout_sec": 60,
          "rule_token_budget": 6000
        }
        """
        let limits = try JSONDecoder().decode(Limits.self, from: Data(json.utf8))
        #expect(limits.mineTimeoutSec == 3600)
        #expect(limits.scannerTimeoutSec == 120)
        #expect(limits.learnIntervalMinutes == 0)
    }

    @Test
    func clampMineAndAgentTimeouts() {
        #expect(Limits.clampMineTimeout(1) == 60)
        #expect(Limits.clampMineTimeout(99_999) == Limits.maxMineTimeoutSec)
        #expect(Limits.clampAgentTimeout(1) == 60)
        #expect(Limits.clampAgentTimeout(99_999) == Limits.maxAgentTimeoutSec)
        #expect(Limits.v1.mineTimeoutSec == 3600)
        #expect(Limits.v1.agentTimeoutSec == 900)
    }

    @Test
    func envOverridesMineAndAgentTimeouts() {
        let config = GegenlesenConfig.example.applyingEnvironmentOverrides([
            "GEGENLESEN_MINE_TIMEOUT_SEC": "14400",
            "GEGENLESEN_AGENT_TIMEOUT_SEC": "1800",
        ])
        #expect(config.limits.mineTimeoutSec == 14_400)
        #expect(config.limits.agentTimeoutSec == 1_800)
    }

    @Test
    func minerModelDefaultsToJudgeWhenOmitted() throws {
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
        #expect(config.minerModel == "openrouter/judge")
    }

    @Test
    func envOverridesMinerModel() {
        let config = GegenlesenConfig.example.applyingEnvironmentOverrides([
            "GEGENLESEN_MINER_MODEL": "openrouter/custom/miner",
        ])
        #expect(config.minerModel == "openrouter/custom/miner")
        #expect(config.judgeModel == GegenlesenConfig.example.judgeModel)
    }

    @Test
    func envClampsMineTimeout() {
        let high = GegenlesenConfig.example.applyingEnvironmentOverrides([
            "GEGENLESEN_MINE_TIMEOUT_SEC": "999999",
        ])
        #expect(high.limits.mineTimeoutSec == Limits.maxMineTimeoutSec)
        let empty = GegenlesenConfig.example.applyingEnvironmentOverrides([
            "GEGENLESEN_MINE_TIMEOUT_SEC": "",
        ])
        #expect(empty.limits.mineTimeoutSec == 3600)
    }

    @Test
    func providerEnvForwardsGrokKeys() {
        let env = GegenlesenConfig.example.providerEnv(from: [
            "XAI_API_KEY": "xai-test",
            "GROK_API_KEY": "grok-test",
        ])
        #expect(env["XAI_API_KEY"] == "xai-test")
        #expect(env["GROK_API_KEY"] == "grok-test")
    }

    @Test
    func mineEngineEnvOverrideIgnoresNonOpenCode() {
        let config = GegenlesenConfig.example.applyingEnvironmentOverrides([
            "GEGENLESEN_MINE_ENGINE": "claude",
        ])
        #expect(config.engineProfiles.mine.engine == "opencode")
    }
}
