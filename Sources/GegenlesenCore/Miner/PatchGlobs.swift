import Foundation

public enum PatchGlobs: Sendable {
    public static func from(patch: Data) -> [String] {
        let text = String(data: patch, encoding: .utf8) ?? ""
        var globs: [String] = []
        var seen = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let path: String?
            if line.hasPrefix("+++ b/") {
                path = String(line.dropFirst(6))
            } else if line.hasPrefix("diff --git ") {
                path = gitBPath(String(line))
            } else {
                path = nil
            }
            guard let path, path != "/dev/null" else { continue }
            let glob = glob(forPath: path)
            if seen.insert(glob).inserted {
                globs.append(glob)
            }
        }
        return globs.isEmpty ? ["**/*"] : globs
    }

    public static func equivalent(_ lhs: [String], _ rhs: [String]) -> Bool {
        Set(lhs) == Set(rhs)
    }

    public static func glob(forPath path: String) -> String {
        let name: String
        if let slash = path.lastIndex(of: "/") {
            name = String(path[path.index(after: slash)...])
        } else {
            name = path
        }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return "**/*\(name[dot...])"
        }
        return "**/*"
    }

    private static func gitBPath(_ line: String) -> String? {
        // diff --git a/foo.swift b/foo.swift
        guard let marker = line.range(of: " b/") else { return nil }
        return String(line[marker.upperBound...])
    }
}
