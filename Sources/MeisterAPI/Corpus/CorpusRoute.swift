import Foundation
import MeisterCore
import Vapor

enum CorpusRoute {
    static func register(_ app: Application) {
        app.get("api", "corpus", use: list)
        app.post("api", "corpus", use: ingest)
        app.post("api", "corpus", "mine", use: mine)
        app.get("api", "corpus", ":id", use: detail)
    }

    static func list(_ req: Request) async throws -> CorpusListResponse {
        let items = try await req.application.meisterStore.listCorpusItems()
        return CorpusListResponse(items: items.map(CorpusItemDTO.init(item:)))
    }

    static func detail(_ req: Request) async throws -> CorpusItemDTO {
        guard let raw = req.parameters.get("id") else {
            throw APIError.notFound()
        }
        guard let item = try await req.application.meisterStore.corpusItem(id: raw) else {
            throw APIError.notFound()
        }
        return CorpusItemDTO(item: item)
    }

    static func ingest(_ req: Request) async throws -> Response {
        let parts = try parseItems(req)
        if parts.isEmpty {
            throw APIError.badRequest("missing item")
        }
        let limit = req.application.meisterConfig.limits.archiveBytes
        var accepted = 0
        var pendingPairs: [String: (patch: Data?, json: Data?)] = [:]
        let ingest = CorpusIngest()
        let store = req.application.meisterStore

        for part in parts {
            if part.data.count > limit {
                throw APIError.payloadTooLarge("item exceeds archive_bytes")
            }
            let name = part.filename
            if isArchiveName(name) || isGzipMagic(part.data) {
                _ = try await ingest.persistArchive(
                    archive: part.data,
                    filename: name,
                    store: store
                )
                accepted += 1
                continue
            }
            let label = CorpusIngest.label(from: name)
            var pair = pendingPairs[label] ?? (nil, nil)
            if name.lowercased().hasSuffix(".json") {
                pair.json = part.data
            } else {
                pair.patch = part.data
            }
            pendingPairs[label] = pair
        }

        for (label, pair) in pendingPairs {
            _ = try await ingest.persistPair(
                patch: pair.patch ?? Data(),
                json: pair.json,
                sourceLabel: label,
                store: store
            )
            accepted += 1
        }

        return try encoded(CorpusAccepted(accepted: accepted), status: .accepted, on: req)
    }

    static func mine(_ req: Request) async throws -> Response {
        let body = (try? req.content.decode(MineRequest.self)) ?? MineRequest()
        if let ids = body.itemIDs {
            for id in ids {
                if try await req.application.meisterStore.corpusItem(id: id) == nil {
                    throw APIError.notFound("unknown corpus item")
                }
            }
        }
        return try await enqueueMine(
            on: req,
            spec: MineJobSpec(source: .corpus, itemIDs: body.itemIDs),
            title: "mine corpus"
        )
    }

    static func enqueueMine(
        on req: Request,
        spec: MineJobSpec,
        title: String,
        parentJobID: JobID? = nil
    ) async throws -> Response {
        let config = req.application.meisterConfig
        let id = JobID.generate()
        let now = Date()
        let job = Job(
            id: id,
            createdAt: now,
            updatedAt: now,
            status: .queued,
            scope: .full,
            parentJobID: parentJobID,
            title: title,
            reviewerAModelID: config.models.modelA,
            reviewerBModelID: config.models.modelB,
            judgeModelID: config.judgeModel
        )
        let specURL = req.application.meisterStore.blobs.mineSpecURL(jobID: id.rawValue)
        try req.application.meisterStore.blobs.ensureLayout()
        try JSONEncoder().encode(spec).write(to: specURL, options: .atomic)
        try await req.application.meisterStore.insertJob(job)
        try await req.application.meisterStore.appendEvent(jobID: id, level: .info, message: "mine_queued")
        try await req.application.meisterJobs.pushMine(id)
        return try encoded(MineAccepted(jobID: id), status: .accepted, on: req)
    }

    private static func parseItems(_ req: Request) throws -> [(filename: String, data: Data)] {
        struct Parts: Content {
            var item: [File]

            enum CodingKeys: String, CodingKey {
                case item
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let many = try? container.decode([File].self, forKey: .item) {
                    item = many
                } else if let one = try container.decodeIfPresent(File.self, forKey: .item) {
                    item = [one]
                } else {
                    item = []
                }
            }
        }

        let parts: Parts
        do {
            parts = try req.content.decode(Parts.self)
        } catch {
            throw APIError.badRequest("missing item")
        }
        return parts.item.map { file in
            (file.filename.isEmpty ? "item" : file.filename, Data(buffer: file.data))
        }
    }

    private static func isArchiveName(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") || lower.hasSuffix(".tar")
    }

    private static func isGzipMagic(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B
    }

    private static func encoded<T: Content>(_ body: T, status: HTTPResponseStatus, on req: Request) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        let data = try JSONCoding.encoder.encode(body)
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}
