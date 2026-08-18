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
            if let url = ArchivePath.containedURL(root: root, relative: quarantined),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        guard let url = ArchivePath.containedURL(root: root, relative: relative) else {
            return nil
        }
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    public static func isRenamedOpenCodeConfig(_ relative: String) -> Bool {
        relative == "opencode.json"
            || relative == "opencode.jsonc"
            || relative == ".opencode"
            || relative.hasPrefix(".opencode/")
    }
}
