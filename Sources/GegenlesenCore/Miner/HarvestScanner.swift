import Foundation

public struct HarvestScan: Codable, Sendable, Equatable {
    public var suppressions: [HarvestSuppression]
    public var prose: [HarvestProse]

    public init(suppressions: [HarvestSuppression] = [], prose: [HarvestProse] = []) {
        self.suppressions = suppressions
        self.prose = prose
    }
}

public struct HarvestSuppression: Codable, Sendable, Equatable {
    public var path: String
    public var tool: String

    public init(path: String, tool: String) {
        self.path = path
        self.tool = tool
    }
}

public struct HarvestProse: Codable, Sendable, Equatable {
    public var path: String
    public var excerpt: String

    public init(path: String, excerpt: String) {
        self.path = path
        self.excerpt = excerpt
    }
}

public enum HarvestScanner: Sendable {
    private static let skipNames: Set<String> = [
        ".git", "node_modules", ".build", "dist", "var", "vendor", ".next",
        "Pods", "DerivedData", "target", "__pycache__", ".venv", "frontend/node_modules",
    ]

    private static let proseNames: Set<String> = [
        "readme.md", "readme", "contributing.md", "contributing",
        "agents.md", "claude.md", "codeowners", "security.md",
    ]

    public static func scan(root: URL, fileManager: FileManager = .default) -> HarvestScan {
        var suppressions: [HarvestSuppression] = []
        var prose: [HarvestProse] = []
        walk(root: root, relative: "", fileManager: fileManager, suppressions: &suppressions, prose: &prose)
        return HarvestScan(
            suppressions: Array(suppressions.prefix(40)),
            prose: Array(prose.prefix(20))
        )
    }

    public static func write(_ scan: HarvestScan, workspace: URL) throws {
        let dir = workspace.appendingPathComponent(".gegenlesen", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(scan).write(
            to: dir.appendingPathComponent("harvest-scan.json"),
            options: .atomic
        )
    }

    private static func walk(
        root: URL,
        relative: String,
        fileManager: FileManager,
        suppressions: inout [HarvestSuppression],
        prose: inout [HarvestProse]
    ) {
        let dir = relative.isEmpty ? root : root.appendingPathComponent(relative)
        let items = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in items.sorted() {
            if name.hasPrefix(".") && name != ".github" && name != ".editorconfig"
                && name != ".swiftlint.yml" && name != ".pre-commit-config.yaml" {
                if name != ".eslintrc" && !name.hasPrefix(".eslintrc") { continue }
            }
            let childRel = relative.isEmpty ? name : relative + "/" + name
            if skipNames.contains(name) { continue }
            var isDir: ObjCBool = false
            let path = dir.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: path.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if suppressions.count + prose.count > 80 { return }
                walk(
                    root: root,
                    relative: childRel,
                    fileManager: fileManager,
                    suppressions: &suppressions,
                    prose: &prose
                )
                continue
            }
            classify(path: path, relative: childRel, suppressions: &suppressions, prose: &prose)
        }
    }

    private static func classify(
        path: URL,
        relative: String,
        suppressions: inout [HarvestSuppression],
        prose: inout [HarvestProse]
    ) {
        let lower = relative.lowercased()
        let base = URL(fileURLWithPath: lower).lastPathComponent
        if let tool = toolName(for: lower, base: base) {
            suppressions.append(HarvestSuppression(path: relative, tool: tool))
            return
        }
        let isProse = proseNames.contains(base)
            || lower.hasPrefix("docs/") && lower.hasSuffix(".md")
            || lower.contains("/adr") && lower.hasSuffix(".md")
        guard isProse else { return }
        let excerpt = readExcerpt(path)
        guard !excerpt.isEmpty else { return }
        prose.append(HarvestProse(path: relative, excerpt: excerpt))
    }

    private static func toolName(for lower: String, base: String) -> String? {
        if base.hasPrefix(".eslintrc") || base == "eslint.config.js" || base == "eslint.config.mjs" {
            return "eslint"
        }
        if base == "biome.json" || base == "biome.jsonc" { return "biome" }
        if base == ".swiftlint.yml" || base == ".swiftlint.yaml" { return "swiftlint" }
        if base == ".editorconfig" { return "editorconfig" }
        if base == "ruff.toml" || lower.hasSuffix("/ruff.toml") { return "ruff" }
        if base == ".pre-commit-config.yaml" { return "pre-commit" }
        if base == ".clang-format" { return "clang-format" }
        if lower.contains(".github/workflows/") && (lower.hasSuffix(".yml") || lower.hasSuffix(".yaml")) {
            return "github-actions"
        }
        return nil
    }

    private static func readExcerpt(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 6_000)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
