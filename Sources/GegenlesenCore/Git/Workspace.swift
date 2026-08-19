#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

public struct Workspace: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public func resolveForRead(_ filePath: String) -> URL? {
        guard let relative = resolvedRelative(filePath) else { return nil }
        return ArchivePath.containedURL(root: root, relative: relative)
    }

    /// Reads by opening each path component with `O_NOFOLLOW` (`openat`).
    public func readRegularFile(_ filePath: String) -> Data? {
        guard let relative = resolvedRelative(filePath),
              let fd = openEachComponent(relative)
        else { return nil }
        defer { close(fd) }
        return Self.readAll(fd)
    }

    public func lineSliceMatches(
        filePath: String,
        startLine: Int,
        endLine: Int,
        snippet: String
    ) -> Bool {
        guard let data = readRegularFile(filePath),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard startLine >= 1, startLine <= lines.count else { return false }
        let start = startLine - 1
        let end = min(endLine, lines.count)
        guard end > start else { return false }
        let slice = lines[start..<end].joined(separator: "\n")
        return Fingerprint.normalizeWhitespace(slice)
            .contains(Fingerprint.normalizeWhitespace(snippet))
    }

    public func removeEscapingSymlinks() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        ) else { return }
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values?.isSymbolicLink == true else { continue }
            if !isSafeSymlink(url) {
                try? fm.removeItem(at: url)
            }
            if values?.isDirectory == true {
                enumerator.skipDescendants()
            }
        }
    }

    public static func isRenamedOpenCodeConfig(_ relative: String) -> Bool {
        relative == "opencode.json"
            || relative == "opencode.jsonc"
            || relative == ".opencode"
            || relative.hasPrefix(".opencode/")
    }

    private func resolvedRelative(_ filePath: String) -> String? {
        guard let relative = try? ArchivePath.normalizedRelative(filePath), !relative.isEmpty else {
            return nil
        }
        if Self.isRenamedOpenCodeConfig(relative) {
            let quarantined = ".gegenlesen/quarantine/" + relative
            if let fd = openEachComponent(quarantined) {
                close(fd)
                return quarantined
            }
        }
        guard let fd = openEachComponent(relative) else { return nil }
        close(fd)
        return relative
    }

    /// Opens `relative` under `root` one component at a time so intermediate symlinks cannot escape.
    private func openEachComponent(_ relative: String) -> Int32? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for (index, part) in parts.enumerated() {
            var flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            if index < parts.count - 1 {
                flags |= O_DIRECTORY
            }
            let next = part.withCString { name in
                openat(fd, name, flags)
            }
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        var info = stat()
        if fstat(fd, &info) != 0 || (info.st_mode & S_IFMT) != S_IFREG {
            close(fd)
            return nil
        }
        return fd
    }

    private static func readAll(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n == 0 { break }
            if n < 0 { return nil }
            data.append(buffer, count: Int(n))
        }
        return data
    }

    private func isSafeSymlink(_ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard urlPath == rootPath || urlPath.hasPrefix(prefix) else { return false }
        let relative = String(urlPath.dropFirst(prefix.count))
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        return (try? ArchivePath.symlinkDestination(
            workspace: root,
            linkRelative: relative,
            target: dest
        )) != nil
    }

}
