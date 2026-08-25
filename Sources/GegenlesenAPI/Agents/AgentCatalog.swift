import Foundation
import GegenlesenCore
import Vapor

enum AgentSource: String, Content, Sendable, Equatable {
    case packaged
    case global
    case repository
}

struct AgentDTO: Content, Sendable, Equatable {
    var id: String
    var description: String
    var prompt: String
    var customized: Bool
    var source: AgentSource
    var repository: String?
    var requiredPaths: [String]

    enum CodingKeys: String, CodingKey {
        case id, description, prompt, customized, source, repository
        case requiredPaths = "required_paths"
    }
}

struct AgentListDTO: Content, Sendable, Equatable {
    var agents: [AgentDTO]
    var minerModel: String
    var repository: String?

    enum CodingKeys: String, CodingKey {
        case agents, repository
        case minerModel = "miner_model"
    }
}

struct AgentUpdate: Content, Sendable, Equatable {
    var prompt: String
    var repository: String? = nil
}

struct AgentScope: Content, Sendable, Equatable {
    var repository: String? = nil
}

struct AgentImproveRequest: Content, Sendable, Equatable {
    var instruction: String
    var prompt: String? = nil
    var repository: String? = nil
}

struct AgentImproveResponse: Content, Sendable, Equatable {
    var prompt: String
}

enum AgentCatalog {
    static let ids = ["reviewer", "judge", "miner", "harvester", "suggestion-judge"]
    static let maxPromptChars = 100_000
    static let maxInstructionChars = 8_000

    static let requiredPaths: [String: [String]] = [
        "reviewer": [
            ".gegenlesen/prompt.md",
            ".gegenlesen/files.json",
            ".gegenlesen/diff.patch",
            ".gegenlesen/rules.json",
            ".gegenlesen/findings-model_a.json",
            ".gegenlesen/findings-model_b.json",
            ".gegenlesen/findings.schema.json",
        ],
        "judge": [
            ".gegenlesen/judge-input.json",
            ".gegenlesen/judge.json",
        ],
        "miner": [
            ".gegenlesen/mined-rules.json",
        ],
        "harvester": [
            ".gegenlesen/harvest.json",
            ".gegenlesen/harvest-scan.json",
            ".gegenlesen/prompt.md",
        ],
        "suggestion-judge": [
            ".gegenlesen/prompt-suggestion-judge.md",
            ".gegenlesen/suggestion-judge-input.json",
            ".gegenlesen/suggestion-judge.json",
        ],
    ]

    static func requireID(_ raw: String) throws -> String {
        guard ids.contains(raw) else {
            throw APIError.notFound("unknown agent")
        }
        return raw
    }

    static func paths(for id: String) -> [String] {
        requiredPaths[id] ?? []
    }

    static func missingPaths(id: String, prompt: String) -> [String] {
        paths(for: id).filter { !prompt.contains($0) }
    }

    static func requirePaths(id: String, prompt: String) throws {
        let missing = missingPaths(id: id, prompt: prompt)
        guard missing.isEmpty else {
            throw APIError.unprocessable(
                "prompt is missing required paths: \(missing.joined(separator: ", "))"
            )
        }
    }

    static func repoKey(_ repository: String) -> String? {
        guard let name = RepositoryName.normalize(repository) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return name.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    static func description(from prompt: String) -> String {
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else { return "" }
        for line in lines.dropFirst() {
            if line == "---" { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("description:") {
                return String(trimmed.dropFirst("description:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}

struct AgentStore {
    var workingDirectory: String
    var dataDir: String
    var fileManager: FileManager = .default

    func list(repository: String? = nil) throws -> [AgentDTO] {
        try AgentCatalog.ids.map { try get($0, repository: repository) }
    }

    func get(_ id: String, repository: String? = nil) throws -> AgentDTO {
        let id = try AgentCatalog.requireID(id)
        let repo = RepositoryName.normalize(repository)
        let resolved = try resolved(id: id, repository: repo)
        return AgentDTO(
            id: id,
            description: AgentCatalog.description(from: resolved.prompt),
            prompt: resolved.prompt,
            customized: resolved.customized,
            source: resolved.source,
            repository: repo,
            requiredPaths: AgentCatalog.paths(for: id)
        )
    }

    func put(_ id: String, prompt: String, repository: String? = nil) throws -> AgentDTO {
        let id = try AgentCatalog.requireID(id)
        let repo = RepositoryName.normalize(repository)
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.unprocessable("prompt is required")
        }
        guard trimmed.count <= AgentCatalog.maxPromptChars else {
            throw APIError.payloadTooLarge("prompt is too long")
        }
        try AgentCatalog.requirePaths(id: id, prompt: trimmed)
        let url = try overrideURL(id: id, repository: repo)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try trimmed.write(to: url, atomically: true, encoding: .utf8)
        if repo == nil {
            try publish(id, prompt: trimmed)
        }
        return try get(id, repository: repo)
    }

    func reset(_ id: String, repository: String? = nil) throws -> AgentDTO {
        let id = try AgentCatalog.requireID(id)
        let repo = RepositoryName.normalize(repository)
        let url = try overrideURL(id: id, repository: repo)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        if repo == nil {
            try restorePackaged(id)
        }
        return try get(id, repository: repo)
    }

    func resolvedPrompt(id: String, repository: String?) throws -> String {
        try resolved(id: id, repository: RepositoryName.normalize(repository)).prompt
    }

    func packagedPrompt(_ id: String) throws -> String {
        let url = packagedURL(id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw APIError.notFound("packaged agent missing")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func customDir() -> URL {
        URL(fileURLWithPath: dataDir, isDirectory: true).appendingPathComponent("agents", isDirectory: true)
    }

    func customURL(_ id: String) -> URL {
        customDir().appendingPathComponent("\(id).md")
    }

    func repoURL(repository: String, id: String) throws -> URL {
        guard let key = AgentCatalog.repoKey(repository) else {
            throw APIError.unprocessable("repository is required")
        }
        return customDir()
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("\(id).md")
    }

    func overrideURL(id: String, repository: String?) throws -> URL {
        if let repository {
            return try repoURL(repository: repository, id: id)
        }
        return customURL(id)
    }

    private struct Resolved {
        var prompt: String
        var source: AgentSource
        var customized: Bool
    }

    private func resolved(id: String, repository: String?) throws -> Resolved {
        if let repository {
            let url = try repoURL(repository: repository, id: id)
            if let text = read(url) {
                return Resolved(prompt: text, source: .repository, customized: true)
            }
        }
        if let text = read(customURL(id)) {
            return Resolved(prompt: text, source: .global, customized: repository == nil)
        }
        return Resolved(prompt: try packagedPrompt(id), source: .packaged, customized: false)
    }

    private func read(_ url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func packagedURL(_ id: String) -> URL {
        URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent("docker/opencode-runner/agents/\(id).md")
    }

    func runnerAgentsDir() -> URL {
        URL(fileURLWithPath: dataDir, isDirectory: true)
            .appendingPathComponent("opencode-runner/agents", isDirectory: true)
    }

    func publish(_ id: String, prompt: String) throws {
        let destDir = runnerAgentsDir()
        guard fileManager.fileExists(atPath: destDir.path) else { return }
        let dest = destDir.appendingPathComponent("\(id).md")
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try prompt.write(to: dest, atomically: true, encoding: .utf8)
    }

    func restorePackaged(_ id: String) throws {
        let destDir = runnerAgentsDir()
        guard fileManager.fileExists(atPath: destDir.path) else { return }
        let dest = destDir.appendingPathComponent("\(id).md")
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        let packaged = packagedURL(id)
        if fileManager.fileExists(atPath: packaged.path) {
            try fileManager.copyItem(at: packaged, to: dest)
        }
    }
}

func overlayCustomAgents(
    dataDir: String,
    dest: URL,
    fileManager: FileManager = .default,
    workingDirectory: String = "",
    repository: String? = nil
) throws {
    let dataPath = URL(fileURLWithPath: dataDir, isDirectory: true).standardizedFileURL.path
    let destPath = dest.standardizedFileURL.path
    let prefix = dataPath.hasSuffix("/") ? dataPath : dataPath + "/"
    guard destPath == dataPath || destPath.hasPrefix(prefix) else { return }
    guard fileManager.fileExists(atPath: dest.path) else { return }
    let destAgents = dest.appendingPathComponent("agents", isDirectory: true)
    try fileManager.createDirectory(at: destAgents, withIntermediateDirectories: true)
    let store = AgentStore(
        workingDirectory: workingDirectory,
        dataDir: dataDir,
        fileManager: fileManager
    )
    for id in AgentCatalog.ids {
        guard let prompt = try? store.resolvedPrompt(id: id, repository: repository) else { continue }
        let dst = destAgents.appendingPathComponent("\(id).md")
        if fileManager.fileExists(atPath: dst.path) {
            try fileManager.removeItem(at: dst)
        }
        try prompt.write(to: dst, atomically: true, encoding: .utf8)
    }
}
