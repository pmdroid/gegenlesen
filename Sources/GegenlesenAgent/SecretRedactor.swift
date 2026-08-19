import Foundation

public struct SecretRedactor: Sendable {
    public static let placeholder = "[REDACTED]"

    public init() {}

    public func redact(_ text: String) -> String {
        var result = text
        result = redactPEM(result)
        result = redactEnvAssignments(result)
        result = redactSkTokens(result)
        result = redactSlackTokens(result)
        return result
    }

    public func redact(_ data: Data) -> Data {
        Data(redact(String(data: data, encoding: .utf8) ?? "").utf8)
    }

    private func redactSkTokens(_ text: String) -> String {
        text.replacing(#/sk-[A-Za-z0-9_-]{8,}/#, with: { _ in Self.placeholder })
    }

    private func redactSlackTokens(_ text: String) -> String {
        text.replacing(#/xox[baprs]-[A-Za-z0-9-]{8,}/#, with: { _ in Self.placeholder })
    }

    private func redactEnvAssignments(_ text: String) -> String {
        text.replacing(
            #/(ANTHROPIC_API_KEY|OPENAI_API_KEY|OPENROUTER_API_KEY)\s*[:=]\s*["']?[^\s"',}]+["']?/#,
            with: { match in
                let name = String(match.output.1)
                return "\(name)=\(Self.placeholder)"
            }
        )
    }

    private func redactPEM(_ text: String) -> String {
        text.replacing(
            #/-----BEGIN [A-Z ]+PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+PRIVATE KEY-----/#,
            with: { _ in Self.placeholder }
        )
    }
}
