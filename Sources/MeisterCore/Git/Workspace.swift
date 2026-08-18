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
        guard let relative = try? ArchivePath.normalizedRelative(filePath), !relative.isEmpty else {
            return nil
        }
        if Self.isRenamedOpenCodeConfig(relative) {
            let quarantined = ".meister/quarantine/" + relative
            if let url = regularFileIfContained(relative: quarantined) {
                return url
            }
        }
        return regularFileIfContained(relative: relative)
    }

    /// Reads without following the last path component (`O_NOFOLLOW`).
    public func readRegularFile(_ filePath: String) -> Data? {
        guard let url = resolveForRead(filePath) else { return nil }
        return Self.readNoFollow(url)
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

    private func regularFileIfContained(relative: String) -> URL? {
        guard let url = ArchivePath.containedURL(root: root, relative: relative) else {
            return nil
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            return nil
        }
        if (info.st_mode & S_IFMT) != S_IFREG {
            return nil
        }
        return url
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

    static func readNoFollow(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
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
}
