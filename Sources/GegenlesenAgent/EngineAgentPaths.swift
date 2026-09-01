import Foundation

public enum EngineAgentPaths {
    public static func cursorAgent(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = EngineHostCredentials.hostHomeDirectory()
    ) -> String? {
        if let override = nonEmpty(environment["GEGENLESEN_CURSOR_AGENT"]), FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            home.appendingPathComponent(".local/bin/agent").path,
            "/usr/local/bin/agent",
            "/opt/homebrew/bin/agent",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            if !isGrokAgent(at: path) { return path }
        }
        return which("agent", environment: environment).flatMap { path in
            isGrokAgent(at: path) ? nil : path
        }
    }

    public static func grokAgent(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = EngineHostCredentials.hostHomeDirectory()
    ) -> String? {
        if let override = nonEmpty(environment["GEGENLESEN_GROK_AGENT"]), FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = [
            home.appendingPathComponent(".grok/bin/agent").path,
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return which("agent", environment: environment).flatMap { path in
            isGrokAgent(at: path) ? path : nil
        }
    }

    private static func isGrokAgent(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.lowercased().contains("grok")
    }

    private static func which(_ name: String, environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let out, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) else { return nil }
        return out
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
