import Foundation

public struct RuleExample: Codable, Sendable, Equatable {
    public var path: String?
    public var excerpt: String
    public var note: String?

    public init(path: String? = nil, excerpt: String, note: String? = nil) {
        self.path = path
        self.excerpt = excerpt
        self.note = note
    }
}

public enum RulePayload: Equatable, Sendable {
    case regex(pattern: String, flags: String?, message: String)
    case denyAPI(symbols: [String], message: String)
    case siblingTest(sourceGlob: String, testTemplate: String)
    case command(argv: [String], timeoutSec: Int)
    case openapiBreak(specGlobs: [String], failOn: String, message: String)
    case semantic(instruction: String, fewShots: [String])

    public var isSemantic: Bool {
        if case .semantic = self { return true }
        return false
    }
}

public struct Rule: Sendable, Equatable {
    public var id: RuleID
    public var title: String
    public var severity: Severity
    public var kind: RuleKind
    public var enabled: Bool
    public var deletedAt: Date?
    public var provenance: RuleProvenance
    public var languages: [String]
    public var pathGlobs: [String]
    public var repository: String?
    public var payload: RulePayload
    public var examples: [RuleExample]
    public var sourcePRRefs: [String]
    public var promotedFromRuleID: RuleID?
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: RuleID,
        title: String,
        severity: Severity,
        kind: RuleKind,
        enabled: Bool = true,
        deletedAt: Date? = nil,
        provenance: RuleProvenance = .handwritten,
        languages: [String],
        pathGlobs: [String],
        repository: String? = nil,
        payload: RulePayload,
        examples: [RuleExample] = [],
        sourcePRRefs: [String] = [],
        promotedFromRuleID: RuleID? = nil,
        body: String = "",
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.kind = kind
        self.enabled = enabled
        self.deletedAt = deletedAt
        self.provenance = provenance
        self.languages = languages
        self.pathGlobs = pathGlobs
        self.repository = repository
        self.payload = payload
        self.examples = examples
        self.sourcePRRefs = sourcePRRefs
        self.promotedFromRuleID = promotedFromRuleID
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension RulePayload: Codable {
    enum CodingKeys: String, CodingKey {
        case checker
        case pattern, flags, message
        case symbols
        case sourceGlob = "source_glob"
        case testTemplate = "test_template"
        case argv
        case timeoutSec = "timeout_sec"
        case specGlobs = "spec_globs"
        case failOn = "fail_on"
        case instruction
        case fewShots = "few_shots"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let instruction = try container.decodeIfPresent(String.self, forKey: .instruction) {
            let fewShots = try container.decodeIfPresent([String].self, forKey: .fewShots) ?? []
            self = .semantic(instruction: instruction, fewShots: fewShots)
            return
        }
        let checker = try container.decode(DeterministicCheckerKind.self, forKey: .checker)
        switch checker {
        case .regex:
            self = .regex(
                pattern: try container.decode(String.self, forKey: .pattern),
                flags: try container.decodeIfPresent(String.self, forKey: .flags),
                message: try container.decode(String.self, forKey: .message)
            )
        case .denyApi:
            self = .denyAPI(
                symbols: try container.decode([String].self, forKey: .symbols),
                message: try container.decode(String.self, forKey: .message)
            )
        case .siblingTest:
            self = .siblingTest(
                sourceGlob: try container.decode(String.self, forKey: .sourceGlob),
                testTemplate: try container.decode(String.self, forKey: .testTemplate)
            )
        case .command:
            let raw = try container.decode(Int.self, forKey: .timeoutSec)
            self = .command(
                argv: try container.decode([String].self, forKey: .argv),
                timeoutSec: min(max(raw, 1), 20)
            )
        case .openapiBreak:
            self = .openapiBreak(
                specGlobs: try container.decode([String].self, forKey: .specGlobs),
                failOn: try container.decodeIfPresent(String.self, forKey: .failOn) ?? "breaking",
                message: try container.decode(String.self, forKey: .message)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .regex(let pattern, let flags, let message):
            try container.encode(DeterministicCheckerKind.regex, forKey: .checker)
            try container.encode(pattern, forKey: .pattern)
            try container.encodeIfPresent(flags, forKey: .flags)
            try container.encode(message, forKey: .message)
        case .denyAPI(let symbols, let message):
            try container.encode(DeterministicCheckerKind.denyApi, forKey: .checker)
            try container.encode(symbols, forKey: .symbols)
            try container.encode(message, forKey: .message)
        case .siblingTest(let sourceGlob, let testTemplate):
            try container.encode(DeterministicCheckerKind.siblingTest, forKey: .checker)
            try container.encode(sourceGlob, forKey: .sourceGlob)
            try container.encode(testTemplate, forKey: .testTemplate)
        case .command(let argv, let timeoutSec):
            try container.encode(DeterministicCheckerKind.command, forKey: .checker)
            try container.encode(argv, forKey: .argv)
            try container.encode(min(max(timeoutSec, 1), 20), forKey: .timeoutSec)
        case .openapiBreak(let specGlobs, let failOn, let message):
            try container.encode(DeterministicCheckerKind.openapiBreak, forKey: .checker)
            try container.encode(specGlobs, forKey: .specGlobs)
            try container.encode(failOn, forKey: .failOn)
            try container.encode(message, forKey: .message)
        case .semantic(let instruction, let fewShots):
            try container.encode(instruction, forKey: .instruction)
            try container.encode(fewShots, forKey: .fewShots)
        }
    }
}