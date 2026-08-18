import Foundation

public struct ContextChunk: Sendable, Equatable {
    public var id: String
    public var kind: ChunkKind
    public var ref: String
    public var ordinal: Int
    public var text: String
    public var embedding: Data?
    public var embeddingModel: String?
    public var contentSHA256: String
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: ChunkKind,
        ref: String,
        ordinal: Int = 0,
        text: String,
        embedding: Data? = nil,
        embeddingModel: String? = nil,
        contentSHA256: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.ref = ref
        self.ordinal = ordinal
        self.text = text
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.contentSHA256 = contentSHA256
        self.updatedAt = updatedAt
    }
}
