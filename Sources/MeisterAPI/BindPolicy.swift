import Foundation

enum BindRefused: Error, Equatable, CustomStringConvertible {
    case remote(String)

    var description: String {
        switch self {
        case .remote(let bind):
            return "Refusing to bind \(bind): not a loopback address. Set MEISTER_ALLOW_REMOTE=1 to allow remote binds."
        }
    }
}

enum BindPolicy {
    static func allowRemoteFromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        env["MEISTER_ALLOW_REMOTE"] == "1"
    }

    static func isLoopback(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let lower = trimmed.lowercased()
        if lower == "localhost" || lower == "::1" || lower == "[::1]" {
            return true
        }
        return isIPv4Loopback(lower)
    }

    static func requireLoopbackOrAllowRemote(
        bind: String,
        allowRemote: Bool
    ) throws {
        if !isLoopback(bind) && !allowRemote {
            throw BindRefused.remote(bind)
        }
    }

    private static func isIPv4Loopback(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { part in
            guard let value = UInt8(part) else { return false }
            return String(value) == part
        }
    }
}
