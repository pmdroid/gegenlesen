import Foundation
import GegenlesenCore

public enum ACPEngines: Sendable {
    public static let supported: Set<String> = [AgentEngineID.claude]

    public static func usesACP(_ engine: String) -> Bool {
        supported.contains(engine.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func agentCommand(engine: String, model: String) -> [String] {
        switch engine {
        case AgentEngineID.claude:
            return ["claude-code-acp"]
        default:
            return []
        }
    }

    public static func agentEnv(engine: String, model: String) -> [String: String] {
        switch engine {
        case AgentEngineID.claude:
            return ["ANTHROPIC_MODEL": model]
        default:
            return [:]
        }
    }
}
