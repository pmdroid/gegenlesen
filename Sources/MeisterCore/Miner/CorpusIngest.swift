import Foundation

public struct CorpusIngest: Sendable {
    public init() {}

    public func persistPair(
        patch: Data,
        json: Data?,
        sourceLabel: String,
        store: Store,
        now: Date = Date()
    ) async throws -> CorpusItem {
        let parsed = Self.parseJSON(json)
        return try await writeItem(
            patch: patch,
            json: json ?? Self.encodeSidecar(title: parsed.title, body: parsed.body, comments: parsed.commentsJSON),
            sourceLabel: sourceLabel,
            title: parsed.title,
            body: parsed.body,
            commentsJSON: parsed.commentsJSON,
            store: store,
            now: now
        )
    }

    public func persistArchive(
        archive: Data,
        filename: String,
        store: Store,
        now: Date = Date()
    ) async throws -> CorpusItem {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(
            "meister-corpus-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let archiveURL = scratch.appendingPathComponent("item.tar.gz")
        try archive.write(to: archiveURL, options: .atomic)
        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        try ArchiveUnpacker().unpack(archive: archiveURL, into: unpacked)

        let patch = Self.firstFile(in: unpacked, suffixes: [".patch"]) ?? Data()
        let json = Self.firstFile(in: unpacked, suffixes: [".json"])
        let label = Self.label(from: filename)
        return try await persistPair(patch: patch, json: json, sourceLabel: label, store: store, now: now)
    }

    private func writeItem(
        patch: Data,
        json: Data,
        sourceLabel: String,
        title: String?,
        body: String?,
        commentsJSON: String?,
        store: Store,
        now: Date
    ) async throws -> CorpusItem {
        let id = UUID().uuidString.lowercased()
        try store.blobs.ensureLayout()
        let dir = store.blobs.corpusItemDirectory(itemID: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try patch.write(to: store.blobs.corpusPatchURL(itemID: id), options: .atomic)
        try json.write(to: store.blobs.corpusJSONURL(itemID: id), options: .atomic)
        let item = CorpusItem(
            id: id,
            sourceLabel: sourceLabel,
            title: title,
            body: body,
            commentsJSON: commentsJSON,
            patchRelpath: "corpus/\(id)/item.patch",
            createdAt: now
        )
        try await store.insertCorpusItem(item)
        return item
    }

    public static func label(from filename: String) -> String {
        var name = URL(fileURLWithPath: filename).lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") {
            name.removeLast(7)
        } else if name.lowercased().hasSuffix(".tgz") {
            name.removeLast(4)
        } else if let dot = name.lastIndex(of: ".") {
            name = String(name[..<dot])
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "item" : trimmed
    }

    public static func parseJSON(_ data: Data?) -> (title: String?, body: String?, commentsJSON: String?) {
        guard let data, !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, nil, nil)
        }
        let title = nonempty(object["title"] as? String)
        let body = nonempty(object["body"] as? String)
        let commentsJSON: String?
        if let comments = object["comments"] {
            commentsJSON = (try? JSONSerialization.data(withJSONObject: comments)).flatMap {
                String(data: $0, encoding: .utf8)
            }
        } else {
            commentsJSON = nil
        }
        return (title, body, commentsJSON)
    }

    private static func encodeSidecar(title: String?, body: String?, comments: String?) -> Data {
        var object: [String: Any] = [:]
        if let title { object["title"] = title }
        if let body { object["body"] = body }
        if let comments, let data = comments.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) {
            object["comments"] = parsed
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func firstFile(in root: URL, suffixes: [String]) -> Data? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            if suffixes.contains(where: { name.hasSuffix($0) }),
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
