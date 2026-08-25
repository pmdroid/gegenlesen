import Foundation

protocol PromptImproving: Sendable {
    func improve(model: String, currentPrompt: String, instruction: String) async throws -> String
}

struct DisabledPromptImprover: PromptImproving {
    func improve(model: String, currentPrompt: String, instruction: String) async throws -> String {
        throw APIError.unprocessable("prompt improve is disabled in skip-agent")
    }
}
