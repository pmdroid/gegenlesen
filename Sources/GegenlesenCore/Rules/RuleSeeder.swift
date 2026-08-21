import Foundation
import Yams

public enum RuleSeeder: Sendable {
    public static let retiredIDs: [RuleID] = [RuleID("no-hardcoded-secrets")]

    public static func upsertAbsent(from directory: URL, into store: Store) async throws -> Int {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        let urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yaml" || $0.pathExtension == "yml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var inserted = 0
        for url in urls {
            guard let seed = try? decodeSeed(at: url) else { continue }
            if try await store.insertRuleIfAbsent(seed) {
                inserted += 1
            }
        }
        return inserted
    }

    public static func retire(into store: Store) async throws {
        for id in retiredIDs {
            _ = try await store.softDeleteRule(id: id)
        }
    }

    public static func decodeSeed(at url: URL) throws -> Rule {
        let text = try String(contentsOf: url, encoding: .utf8)
        let file = try YAMLDecoder().decode(SeedFile.self, from: text)
        let now = Date()
        return Rule(
            id: RuleID(file.id),
            title: file.title,
            severity: file.severity,
            kind: file.kind,
            enabled: file.enabled ?? true,
            provenance: file.provenance ?? .handwritten,
            languages: file.languages,
            pathGlobs: file.pathGlobs,
            payload: file.payload,
            examples: file.examples ?? [],
            sourcePRRefs: file.sourcePRRefs ?? [],
            body: file.body ?? "",
            createdAt: now,
            updatedAt: now
        )
    }
}

struct SeedFile: Codable {
    var id: String
    var title: String
    var severity: Severity
    var enabled: Bool?
    var kind: RuleKind
    var provenance: RuleProvenance?
    var languages: [String]
    var pathGlobs: [String]
    var payload: RulePayload
    var examples: [RuleExample]?
    var sourcePRRefs: [String]?
    var body: String?

    enum CodingKeys: String, CodingKey {
        case id, title, severity, enabled, kind, provenance, languages
        case pathGlobs = "path_globs"
        case payload, examples
        case sourcePRRefs = "source_pr_refs"
        case body
    }
}