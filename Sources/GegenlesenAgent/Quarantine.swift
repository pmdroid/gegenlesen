import Foundation
import GegenlesenCore

public enum Quarantine: Sendable {
    public static let copyNames = [
        "opencode.json",
        "opencode.jsonc",
        ".opencode",
        ".claude",
        "CLAUDE.md",
        "AGENTS.md",
    ]

    public static func run(workspace: Workspace) throws {
        let fm = FileManager.default
        let root = workspace.root
        let quarantineRoot = root.appendingPathComponent(".gegenlesen/quarantine", isDirectory: true)
        try fm.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)

        for name in copyNames {
            let source = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let dest = quarantineRoot.appendingPathComponent(name)
            try? fm.removeItem(at: dest)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
        }

        try renameLoadable(root: root, name: "opencode.json")
        try renameLoadable(root: root, name: "opencode.jsonc")
        try renameLoadable(root: root, name: ".opencode")
    }

    private static func renameLoadable(root: URL, name: String) throws {
        let fm = FileManager.default
        let source = root.appendingPathComponent(name)
        guard fm.fileExists(atPath: source.path) else { return }
        let dest = root.appendingPathComponent(name + ".gegenlesen-disabled")
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: source, to: dest)
    }
}
