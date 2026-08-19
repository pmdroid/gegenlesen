import Foundation

public enum RepositoryName: Sendable {
    public static func normalize(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("git@") {
            let rest = String(value.dropFirst(4))
            if let colon = rest.firstIndex(of: ":") {
                value = String(rest[..<colon]) + "/" + String(rest[rest.index(after: colon)...])
            }
        } else if let url = URL(string: value), let host = url.host, !host.isEmpty {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            value = path.isEmpty ? host : "\(host)/\(path)"
        } else if value.hasPrefix("/") || value.hasPrefix(".") {
            value = URL(fileURLWithPath: value).lastPathComponent
        }
        if value.hasSuffix(".git") {
            value = String(value.dropLast(4))
        }
        while value.hasSuffix("/") {
            value.removeLast()
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public static func applies(_ item: String?, to job: String?) -> Bool {
        guard let scoped = normalize(item) else { return true }
        guard let target = normalize(job) else { return false }
        return scoped == target
    }

    public static func detect(in directory: URL) -> String? {
        if let written = readPacked(directory) {
            return written
        }
        return fromGitRemote(in: directory) ?? fromDirectoryName(directory)
    }

    public static func fromGitRemote(
        in directory: URL,
        git: String = "/usr/bin/git"
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", directory.path, "remote", "get-url", "origin"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        return normalize(text)
    }

    public static func fromDirectoryName(_ directory: URL) -> String? {
        normalize(directory.lastPathComponent)
    }

    private static func readPacked(_ directory: URL) -> String? {
        let url = directory.appendingPathComponent(".gegenlesen/repository")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return normalize(text)
    }
}
