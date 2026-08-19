import Foundation

public enum FileChangeStatus: String, Codable, Sendable, Equatable {
    case added, modified, deleted, renamed
}

public enum Language: String, Codable, Sendable, Equatable {
    case swift, typescript, javascript, python, go, rust, jvm
    case c, ruby, csharp, shell, yaml, json, markdown, other
}

public enum JobStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case queued
    case unpacking
    case identifying
    case selectingRules = "selecting_rules"
    case deterministic
    case reviewing
    case judging
    case succeeded
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled: true
        default: false
        }
    }

    public var isActive: Bool { !isTerminal }
}

public enum JobScope: String, Codable, Sendable, Equatable {
    case full
    case incremental
}

public enum ReviewerSlot: String, Codable, Sendable, Equatable {
    case modelA = "model_a"
    case modelB = "model_b"
}

public enum Severity: String, Codable, Sendable, Equatable {
    case info, warning, error

    public var rank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }
}

public enum FindingPhase: String, Codable, Sendable, Equatable {
    case deterministic
    case agent
}

public enum JudgeVerdict: String, Codable, Sendable, Equatable {
    case keep, drop, downgrade, unavailable
}

public enum FindingLifecycle: String, Codable, Sendable, Equatable {
    case new
    case stillOpen = "still_open"
    case resolved
    case relocated
}

public enum RuleKind: String, Codable, Sendable, Equatable {
    case deterministic, semantic
}

public enum RuleProvenance: String, Codable, Sendable, Equatable {
    case handwritten, mined, suggested, harvest
}

public enum FeedbackVerdict: String, Codable, Sendable, Equatable {
    case agree, disagree, comment, shouldBeRule = "should_be_rule"

    public var isCurrentVerdict: Bool {
        switch self {
        case .agree, .disagree, .shouldBeRule: true
        case .comment: false
        }
    }
}

public enum FeedbackReaction: String, Codable, Sendable, Equatable {
    case thumbsUp = "thumbs_up"
    case thumbsDown = "thumbs_down"

    public static func normalize(_ raw: String) -> FeedbackReaction? {
        switch raw {
        case "thumbs_up", "+1", "👍": return .thumbsUp
        case "thumbs_down", "-1", "👎": return .thumbsDown
        default: return nil
        }
    }

    public var verdict: FeedbackVerdict {
        switch self {
        case .thumbsUp: .agree
        case .thumbsDown: .disagree
        }
    }
}

public enum ContextNoteKind: String, Codable, Sendable, Equatable {
    case user, architecture
}

public enum ChunkKind: String, Codable, Sendable, Equatable {
    case file, architecture, user, rule
}

public enum LearningKind: String, Codable, Sendable, Equatable {
    case rule, architecture, context
}

public enum LearningStatus: String, Codable, Sendable, Equatable {
    case pending, accepted, dismissed
}

public enum DeterministicCheckerKind: String, Codable, Sendable, Equatable {
    case regex
    case denyApi = "deny_api"
    case siblingTest = "sibling_test"
    case command
    case openapiBreak = "openapi_break"
}

public enum EventLevel: String, Codable, Sendable, Equatable {
    case debug, info, warning, error
}

public enum ErrorCode: String, Codable, Sendable, Equatable {
    case badRequest = "bad_request"
    case notFound = "not_found"
    case forbidden
    case conflict
    case payloadTooLarge = "payload_too_large"
    case unsupportedMediaType = "unsupported_media_type"
    case unprocessable
    case insufficientStorage = "insufficient_storage"
    case `internal` = "internal"
}
