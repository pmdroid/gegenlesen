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
        return ArchivePath.containedURL(root: root, relative: relative)
    }
}
