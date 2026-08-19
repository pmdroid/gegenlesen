import Foundation
import GegenlesenCore
import Vapor

enum HarvestRoute {
    static func register(_ app: Application) {
        app.post("api", "harvest", use: create)
        app.post("api", "harvest", ":id", "ingest", use: ingest)
    }

    static func create(_ req: Request) async throws -> Response {
        let limits = req.application.gegenlesenConfig.limits
        let parsed = try parseArchive(req, archiveLimit: limits.archiveBytes)
        let active = try await req.application.gegenlesenStore.activeArchiveBytes()
        if active + parsed.archive.count > limits.queuedArchiveBytes {
            throw APIError.insufficientStorage("queued archive bytes would exceed limit")
        }

        let config = req.application.gegenlesenConfig
        let id = JobID.generate()
        let now = Date()
        let job = Job(
            id: id,
            createdAt: now,
            updatedAt: now,
            status: .queued,
            scope: .full,
            title: parsed.filename.isEmpty ? "harvest" : "harvest \(parsed.filename)",
            repository: parsed.repository,
            reviewerAModelID: config.models.modelA,
            reviewerBModelID: config.models.modelB,
            judgeModelID: config.judgeModel,
            archiveSHA256: ContentHash.sha256(parsed.archive),
            archiveBytes: parsed.archive.count
        )
        let spec = MineJobSpec(source: .harvest)
        let blobs = req.application.gegenlesenStore.blobs
        try blobs.ensureLayout()
        try parsed.archive.write(to: blobs.archiveURL(jobID: id.rawValue))
        try JSONEncoder().encode(spec).write(to: blobs.mineSpecURL(jobID: id.rawValue), options: .atomic)
        try await req.application.gegenlesenStore.insertJob(job)
        try await req.application.gegenlesenStore.appendEvent(jobID: id, level: .info, message: "harvest_queued")
        try await req.application.gegenlesenJobs.pushMine(id)
        let position = try await req.application.gegenlesenStore.queuePosition(createdAt: now)
        return try encoded(
            JobAccepted(id: id, status: .queued, queuePosition: max(position, 1)),
            status: .accepted,
            on: req
        )
    }

    static func ingest(_ req: Request) async throws -> Response {
        guard let raw = req.parameters.get("id") else {
            throw APIError.notFound()
        }
        let id = JobID(raw)
        guard try await req.application.gegenlesenStore.job(id: id) != nil else {
            throw APIError.notFound()
        }
        let pipeline = HarvestPipeline(
            store: req.application.gegenlesenStore,
            skipAgent: true,
            model: "none"
        )
        do {
            let counts = try await pipeline.ingestExistingHarvest(jobID: id)
            return try encoded(
                HarvestIngestResponse(rules: counts.rules, notes: counts.notes),
                status: .ok,
                on: req
            )
        } catch HarvestIngestError.missingHarvestFile {
            throw APIError.notFound()
        }
    }

    private static func parseArchive(
        _ req: Request,
        archiveLimit: Int
    ) throws -> (archive: Data, filename: String, repository: String?) {
        struct Parts: Content {
            var archive: File?
            var repository: String?
        }
        let parts: Parts
        do {
            parts = try req.content.decode(Parts.self)
        } catch {
            throw APIError.badRequest("missing archive")
        }
        guard let archiveFile = parts.archive else {
            throw APIError.badRequest("missing archive")
        }
        let filename = archiveFile.filename
        if filename.lowercased().hasSuffix(".zip") {
            throw APIError.unsupportedMediaType("zip archives are not accepted")
        }
        let archive = Data(buffer: archiveFile.data)
        if archive.count > archiveLimit {
            throw APIError.payloadTooLarge("archive exceeds archive_bytes")
        }
        if archive.count >= 2, archive[0] == 0x50, archive[1] == 0x4B {
            throw APIError.unsupportedMediaType("zip archives are not accepted")
        }
        return (archive, filename, RepositoryName.normalize(parts.repository))
    }

    private static func encoded<T: Content>(
        _ body: T,
        status: HTTPResponseStatus,
        on req: Request
    ) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        let data = try JSONCoding.encoder.encode(body)
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}
