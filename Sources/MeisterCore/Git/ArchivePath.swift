import Foundation

enum ArchivePath {
    static let maxLength = 4096

    static func isSkippedEntry(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name == ".DS_Store" || name.hasPrefix("._")
    }

    static func normalizedRelative(_ path: String) throws -> String {
        var raw = path
        if raw.hasPrefix("./") {
            raw.removeFirst(2)
        }
        if raw.hasPrefix("/") {
            throw ArchiveError.unsafePath(path)
        }
        if raw.count > maxLength {
            throw ArchiveError.pathTooLong
        }

        var parts: [String] = []
        for segment in raw.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." {
                continue
            }
            if segment == ".." {
                guard !parts.isEmpty else {
                    throw ArchiveError.unsafePath(path)
                }
                parts.removeLast()
                continue
            }
            parts.append(String(segment))
        }
        let normalized = parts.joined(separator: "/")
        if normalized.count > maxLength {
            throw ArchiveError.pathTooLong
        }
        return normalized
    }

    static func containedURL(root: URL, relative: String) -> URL? {
        let rootStd = root.standardizedFileURL
        let candidate = relative.isEmpty
            ? rootStd
            : rootStd.appendingPathComponent(relative).standardizedFileURL
        let rootPath = rootStd.path
        let candidatePath = candidate.path
        if candidatePath == rootPath {
            return candidate
        }
        if candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") {
            return candidate
        }
        return nil
    }

    static func symlinkDestination(workspace: URL, linkRelative: String, target: String) throws -> String {
        if target.hasPrefix("/") {
            throw ArchiveError.unsafeSymlink(target)
        }
        let parent: String
        if let slash = linkRelative.lastIndex(of: "/") {
            parent = String(linkRelative[..<slash])
        } else {
            parent = ""
        }
        let joined = parent.isEmpty ? target : parent + "/" + target
        let normalized = try normalizedRelative(joined)
        guard containedURL(root: workspace, relative: normalized) != nil else {
            throw ArchiveError.unsafeSymlink(target)
        }
        return target
    }
}
