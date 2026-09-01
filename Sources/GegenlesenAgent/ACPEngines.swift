import Foundation
import GegenlesenCore

public enum ACPEngines: Sendable {
    public static let supported: Set<String> = [
        AgentEngineID.claude,
        AgentEngineID.codex,
        AgentEngineID.cursorAgent,
        AgentEngineID.grok,
    ]

    public static func usesACP(_ engine: String) -> Bool {
        supported.contains(engine.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func agentCommand(engine: String, model: String) -> [String] {
        switch engine {
        case AgentEngineID.claude:
            return ["claude-agent-acp"]
        case AgentEngineID.codex:
            return ["codex-acp"]
        case AgentEngineID.cursorAgent:
            return ["agent", "--model", model, "acp"]
        case AgentEngineID.grok:
            return ["agent", "agent", "--model", model, "stdio"]
        default:
            return []
        }
    }

    public static func agentEnv(engine: String, model: String) -> [String: String] {
        switch engine {
        case AgentEngineID.claude:
            return ["ANTHROPIC_MODEL": model]
        case AgentEngineID.codex:
            let baseModel = codexBaseModel(from: model)
            let config = codexConfigJSON(baseModel: baseModel)
            return [
                "NO_BROWSER": "1",
                "INITIAL_AGENT_MODE": "agent-full-access",
                "CODEX_CONFIG": config,
                "CODEX_ACP_MODEL": model,
            ]
        case AgentEngineID.cursorAgent:
            return [
                "CURSOR_MODEL": model,
                "CURSOR_ACP_MODEL": model,
            ]
        case AgentEngineID.grok:
            return [
                "GROK_MODEL": model,
                "GROK_ACP_MODEL": model,
            ]
        default:
            return [:]
        }
    }

    public static func engineTmpfs(engine: String) -> [String] {
        let spec = "rw,nosuid,nodev,uid=1000,gid=1000,size=64m"
        switch engine {
        case AgentEngineID.claude:
            return ["/home/gegenlesen:rw,nosuid,nodev,uid=1000,gid=1000,size=512m"]
        case AgentEngineID.codex:
            return ["/home/gegenlesen/.codex:\(spec)"]
        case AgentEngineID.cursorAgent:
            return [
                "/home/gegenlesen/.cursor:\(spec)",
                "/home/gegenlesen/.config/cursor:\(spec)",
            ]
        case AgentEngineID.grok:
            return ["/home/gegenlesen/.grok:\(spec)"]
        default:
            return []
        }
    }

    static func codexBaseModel(from model: String) -> String {
        guard let bracket = model.firstIndex(of: "[") else { return model }
        return String(model[..<bracket])
    }

    static func codexConfigJSON(baseModel: String) -> String {
        let payload: [String: String] = [
            "model": baseModel,
            "sandbox": "disabled",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"model":"","sandbox":"disabled"}"#
        }
        return json
    }
}
