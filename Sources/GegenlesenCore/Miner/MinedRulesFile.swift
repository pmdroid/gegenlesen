import Foundation

public struct MinedRuleDraft: Sendable, Equatable {
    public var id: RuleID?
    public var title: String
    public var severity: Severity
    public var kind: RuleKind
    public var languages: [String]
    public var pathGlobs: [String]
    public var payload: RulePayload
    public var examples: [RuleExample]
    public var sourcePRRefs: [String]
    public var body: String

    public init(
        id: RuleID? = nil,
        title: String,
        severity: Severity = .warning,
        kind: RuleKind = .semantic,
        languages: [String] = [],
        pathGlobs: [String] = ["**/*"],
        payload: RulePayload,
        examples: [RuleExample] = [],
        sourcePRRefs: [String] = [],
        body: String = ""
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.kind = kind
        self.languages = languages
        self.pathGlobs = pathGlobs.isEmpty ? ["**/*"] : pathGlobs
        self.payload = payload
        self.examples = examples
        self.sourcePRRefs = sourcePRRefs
        self.body = body
    }
}

public enum MinedRulesFile: Sendable {
    public static func parse(_ data: Data) throws -> [MinedRuleDraft] {
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
            return wrapped.rules.map(\.draft)
        }
        if let rows = try? decoder.decode([Row].self, from: data) {
            return rows.map(\.draft)
        }
        throw MinedRulesError.invalid
    }

    public enum MinedRulesError: Error, Sendable, Equatable {
        case invalid
    }

    private struct Wrapped: Decodable {
        var rules: [Row]
    }

    private struct Row: Decodable {
        var id: String?
        var title: String
        var severity: Severity?
        var kind: RuleKind?
        var languages: [String]?
        var pathGlobs: [String]?
        var payload: RulePayload?
        var examples: [RuleExample]?
        var sourcePRRefs: [String]?
        var body: String?
        var instruction: String?

        enum CodingKeys: String, CodingKey {
            case id, title, severity, kind, languages, payload, examples, body, instruction
            case pathGlobs = "path_globs"
            case sourcePRRefs = "source_pr_refs"
        }

        var draft: MinedRuleDraft {
            let instruction = self.instruction
                ?? {
                    if case .semantic(let text, _) = payload { return text }
                    return nil
                }()
                ?? body
                ?? title
            let resolvedPayload = payload ?? .semantic(instruction: instruction, fewShots: [])
            return MinedRuleDraft(
                id: id.map { RuleID($0) },
                title: title,
                severity: severity ?? .warning,
                kind: kind ?? (resolvedPayload.isSemantic ? .semantic : .deterministic),
                languages: languages ?? [],
                pathGlobs: pathGlobs ?? ["**/*"],
                payload: resolvedPayload,
                examples: examples ?? [],
                sourcePRRefs: sourcePRRefs ?? [],
                body: body ?? ""
            )
        }
    }
}
