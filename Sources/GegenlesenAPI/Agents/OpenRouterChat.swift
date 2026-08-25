import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct OpenRouterChat: PromptImproving {
    var session: URLSession = .shared
    var resolveKey: @Sendable () -> String?
    var endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    static let systemPrompt = """
    You rewrite one OpenCode agent prompt. Keep the YAML frontmatter.
    Keep required output paths and the ban on the question tool, plan agent, and subagents.
    Apply the operator instruction. Return only the full markdown. No fence. No preamble.
    """

    static func openRouterModelID(_ configured: String) -> String {
        if configured.hasPrefix("openrouter/") {
            return String(configured.dropFirst("openrouter/".count))
        }
        return configured
    }

    static func unwrap(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: nl)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    func improve(model: String, currentPrompt: String, instruction: String) async throws -> String {
        guard let key = resolveKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw APIError.unprocessable("OpenRouter API key is required")
        }
        let body: [String: Any] = [
            "model": Self.openRouterModelID(model),
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                [
                    "role": "user",
                    "content": "Instruction:\n\(instruction)\n\nCurrent prompt:\n\(currentPrompt)\n",
                ],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            throw APIError.unprocessable("could not build OpenRouter request")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://gegenlesen.local", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("gegenlesen", forHTTPHeaderField: "X-Title")
        request.timeoutInterval = 60
        let (responseData, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw APIError.unprocessable("OpenRouter rejected the API key")
        }
        if status < 200 || status >= 300 {
            throw APIError.unprocessable(chatErrorMessage(responseData, status: status))
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: responseData)
        let text = Self.unwrap(decoded.choices.first?.message.content ?? "")
        guard !text.isEmpty else {
            throw APIError.unprocessable("OpenRouter returned an empty prompt")
        }
        return text
    }
}

private struct ChatResponse: Decodable {
    var choices: [Choice]
    struct Choice: Decodable {
        var message: Message
    }
    struct Message: Decodable {
        var content: String?
    }
}

private struct ChatErrorBody: Decodable {
    var error: Payload?
    struct Payload: Decodable {
        var message: String?
    }
}

private func chatErrorMessage(_ data: Data, status: Int) -> String {
    if let parsed = try? JSONDecoder().decode(ChatErrorBody.self, from: data),
       let message = parsed.error?.message, !message.isEmpty {
        return message
    }
    return "OpenRouter chat failed (\(status))"
}
