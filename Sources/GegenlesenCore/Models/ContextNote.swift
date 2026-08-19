import Foundation

public struct ContextNote: Sendable, Equatable {
    public var id: String
    public var kind: ContextNoteKind
    public var title: String
    public var body: String
    public var pathGlobs: [String]
    public var alwaysInclude: Bool
    public var repository: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: ContextNoteKind = .user,
        title: String,
        body: String,
        pathGlobs: [String] = [],
        alwaysInclude: Bool = false,
        repository: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.pathGlobs = pathGlobs
        self.alwaysInclude = alwaysInclude
        self.repository = repository
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}
