import Foundation
import GegenlesenCore

public enum ACPEngines: Sendable {
    public static let supported: Set<String> = [
        AgentEngineID.claude,
        AgentEngineID.codex,
        AgentEngineID.cursorAgent,
    ]

    public static func usesACP(_ engine: String) -> Bool {
        supported.contains(engine.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func agentCommand(engine: String, model: String) -> [String] {
        switch engine {
        case AgentEngineID.claude:
            return ["claude-code-acp"]
        case AgentEngineID.codex:
            return ["codex-acp"]
        case AgentEngineID.cursorAgent:
            return ["agent", "acp"]
        default:
            return []
        }
    }

    public static func agentEnv(engine: String, model: String) -> [String: String] {
        switch engine {
        case AgentEngineID.claude:
            return ["ANTHROPIC_MODEL": model]
        case AgentEngineID.codex:
            let config = #"{"model":"\#(model)","sandbox":"disabled"}"#
            return [
                "NO_BROWSER": "1",
                "INITIAL_AGENT_MODE": "agent-full-access",
                "CODEX_CONFIG": config,
            ]
        case AgentEngineID.cursorAgent:
            return [:]
        default:
            return [:]
        }
    }

    public static func engineTmpfs(engine: String) -> [String] {
        let spec = "rw,nosuid,nodev,uid=1000,gid=1000,size=64m"
        switch engine {
        case AgentEngineID.claude:
            return ["/home/gegenlesen/.claude:\(spec)"]
        case AgentEngineID.codex:
            return ["/home/gegenlesen/.codex:\(spec)"]
        case AgentEngineID.cursorAgent:
            return [
                "/home/gegenlesen/.cursor:\(spec)",
                "/home/gegenlesen/.config/cursor:\(spec)",
            ]
        default:
            return []
        }
    }
}
