import Foundation
import GegenlesenCore
import Vapor

enum ContextRoute {
    static func register(_ app: Application) {
        app.get("api", "context", use: list)
        app.post("api", "context", use: create)
        app.put("api", "context", ":id", use: update)
        app.delete("api", "context", ":id", use: remove)
    }

    static func list(_ req: Request) async throws -> ContextNoteListResponse {
        var unscoped = false
        if let raw = req.query[String.self, at: "unscoped"] {
            unscoped = try parseBool(raw, name: "unscoped")
        }
        let repository: String?
        if req.query[String.self, at: "repository"] == "global" {
            unscoped = true
            repository = nil
        } else {
            repository = RepositoryName.normalize(req.query[String.self, at: "repository"])
        }
        var includeGlobal = false
        if let raw = req.query[String.self, at: "include_global"] {
            includeGlobal = try parseBool(raw, name: "include_global")
        }
        let notes = try await req.application.gegenlesenStore.listContextNotes(
            repository: repository,
            unscoped: unscoped,
            includeGlobal: includeGlobal
        )
        return ContextNoteListResponse(notes: notes.map(ContextNoteDTO.init(note:)))
    }

    static func create(_ req: Request) async throws -> Response {
        let upsert = try decode(req)
        let note = ContextNote(
            title: upsert.title,
            body: upsert.body,
            pathGlobs: upsert.pathGlobs ?? [],
            alwaysInclude: upsert.alwaysInclude ?? false,
            repository: RepositoryName.normalize(upsert.repository)
        )
        try await req.application.gegenlesenStore.insertContextNote(note)
        await reembed(note, on: req)
        return try encoded(ContextNoteDTO(note: note), status: .created, on: req)
    }

    static func update(_ req: Request) async throws -> ContextNoteDTO {
        var existing = try await requireNote(req)
        let upsert = try decode(req)
        existing.title = upsert.title
        existing.body = upsert.body
        if let globs = upsert.pathGlobs {
            existing.pathGlobs = globs
        }
        if let always = upsert.alwaysInclude {
            existing.alwaysInclude = always
        }
        existing.repository = RepositoryName.normalize(upsert.repository)
        existing.updatedAt = Date()
        try await req.application.gegenlesenStore.updateContextNote(existing)
        await reembed(existing, on: req)
        return ContextNoteDTO(note: existing)
    }

    static func remove(_ req: Request) async throws -> ContextNoteDTO {
        let existing = try await requireNote(req)
        guard let deleted = try await req.application.gegenlesenStore.softDeleteContextNote(id: existing.id) else {
            throw APIError.notFound()
        }
        return ContextNoteDTO(note: deleted)
    }

    private static func requireNote(_ req: Request) async throws -> ContextNote {
        guard let raw = req.parameters.get("id") else {
            throw APIError.notFound()
        }
        guard let note = try await req.application.gegenlesenStore.contextNote(id: raw, includeDeleted: false) else {
            throw APIError.notFound()
        }
        return note
    }

    private static func parseBool(_ raw: String, name: String) throws -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: throw APIError.badRequest("invalid \(name)")
        }
    }

    private static func decode(_ req: Request) throws -> ContextNoteUpsert {
        do {
            return try req.content.decode(ContextNoteUpsert.self)
        } catch {
            throw APIError.badRequest("invalid context payload")
        }
    }

    private static func reembed(_ note: ContextNote, on req: Request) async {
        try? await ArchitectureIndexJob(
            store: req.application.gegenlesenStore,
            embedder: req.application.gegenlesenEmbedder
        ).embedNote(note)
    }

    private static func encoded<T: Content>(_ body: T, status: HTTPResponseStatus, on req: Request) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        let data = try JSONCoding.encoder.encode(body)
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}
