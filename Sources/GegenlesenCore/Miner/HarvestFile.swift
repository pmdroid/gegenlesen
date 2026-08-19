import Foundation

public struct HarvestNoteDraft: Sendable, Equatable {
    public var title: String
    public var body: String
    public var evidence: [RuleExample]

    public init(title: String, body: String, evidence: [RuleExample] = []) {
        self.title = title
        self.body = body
        self.evidence = evidence
    }
}

public struct HarvestBundle: Sendable, Equatable {
    public var rules: [MinedRuleDraft]
    public var notes: [HarvestNoteDraft]

    public init(rules: [MinedRuleDraft] = [], notes: [HarvestNoteDraft] = []) {
        self.rules = rules
        self.notes = notes
    }
}

public enum HarvestIngestError: Error, Sendable, Equatable {
    case missingHarvestFile
}

public enum HarvestFile: Sendable {
    public static let maxRules = 10
    public static let maxNotes = 5

    public static func parse(_ data: Data) throws -> HarvestBundle {
        let decoded = try JSONDecoder().decode(Row.self, from: data)
        return HarvestBundle(
            rules: decoded.rules?.map(\.draft) ?? [],
            notes: decoded.notes?.map(\.draft) ?? []
        )
    }

    public static func dropUncited(_ bundle: HarvestBundle) -> HarvestBundle {
        HarvestBundle(
            rules: bundle.rules.filter { !$0.examples.isEmpty || hasCitation($0.body) },
            notes: bundle.notes.filter { !$0.evidence.isEmpty || hasCitation($0.body) }
        )
    }

    public static func cap(_ bundle: HarvestBundle) -> HarvestBundle {
        HarvestBundle(
            rules: Array(bundle.rules.prefix(maxRules)),
            notes: Array(bundle.notes.prefix(maxNotes))
        )
    }

    private static func hasCitation(_ text: String) -> Bool {
        text.contains(".swift") || text.contains(".ts") || text.contains(".go")
            || text.contains(".py") || text.contains("README") || text.contains("`")
    }

    private struct Row: Decodable {
        var rules: [RuleRow]?
        var notes: [NoteRow]?
    }

    private struct RuleRow: Decodable {
        var title: String
        var severity: Severity?
        var kind: RuleKind?
        var languages: [String]?
        var pathGlobs: [String]?
        var payload: RulePayload?
        var instruction: String?
        var body: String?
        var evidence: [RuleExample]?
        var examples: [RuleExample]?

        enum CodingKeys: String, CodingKey {
            case title, severity, kind, languages, payload, instruction, body, evidence, examples
            case pathGlobs = "path_globs"
        }

        var draft: MinedRuleDraft {
            let instruction = self.instruction
                ?? {
                    if case .semantic(let text, _) = payload { return text }
                    return nil
                }()
                ?? body
                ?? title
            let examples = evidence ?? self.examples ?? []
            return MinedRuleDraft(
                title: title,
                severity: severity ?? .warning,
                kind: kind ?? .semantic,
                languages: languages ?? ["*"],
                pathGlobs: pathGlobs ?? ["**/*"],
                payload: payload ?? .semantic(instruction: instruction, fewShots: []),
                examples: examples,
                sourcePRRefs: ["harvest"],
                body: body ?? instruction
            )
        }
    }

    private struct NoteRow: Decodable {
        var title: String
        var body: String
        var evidence: [RuleExample]?

        var draft: HarvestNoteDraft {
            HarvestNoteDraft(title: title, body: body, evidence: evidence ?? [])
        }
    }
}
