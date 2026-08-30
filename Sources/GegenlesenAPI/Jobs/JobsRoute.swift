import Foundation
import GegenlesenAgent
import GegenlesenCore
import Vapor

enum JobsRoute {
    static func register(_ app: Application) {
        app.post("api", "jobs", use: create)
        app.get("api", "jobs", use: list)
        app.get("api", "repositories", use: repositories)
        app.get("api", "jobs", ":id", use: detail)
        app.get("api", "jobs", ":id", "events", use: events)
        app.get("api", "jobs", ":id", "transcript", use: transcript)
        app.get("api", "jobs", ":id", "feedback", use: feedback)
        app.post("api", "jobs", ":id", "cancel", use: cancel)
        app.post("api", "jobs", ":id", "learn", use: learn)
        app.post("api", "jobs", ":id", "risk-label", use: riskLabel)
    }

    static func create(_ req: Request) async throws -> Response {
        let limits = req.application.gegenlesenConfig.limits
        let parsed = try parseMultipart(req, archiveLimit: limits.archiveBytes)
        let meta = try decodeMeta(parsed.meta)

        var parentHeadSHA: String?
        if meta.scope == .incremental {
            guard let parentID = meta.parentJobID, !parentID.rawValue.isEmpty else {
                throw APIError.badRequest("incremental requires parent_job_id")
            }
            let parent = try await req.application.gegenlesenStore.parentState(id: parentID)
            if !parent.exists {
                throw APIError.unprocessable(
                    "parent_job_id must reference a succeeded job",
                    details: ["parent_job_id": parentID.rawValue]
                )
            }
            if !parent.succeeded || !parent.hasSHAs || !parent.hasFiles {
                throw APIError.unprocessable(
                    "parent_job_id must reference a succeeded job with base_sha, head_sha, and job_files",
                    details: ["parent_job_id": parentID.rawValue]
                )
            }
            parentHeadSHA = nonempty(try await req.application.gegenlesenStore.job(id: parentID)?.headSHA)
        }

        let active = try await req.application.gegenlesenStore.activeArchiveBytes()
        if active + parsed.archive.count > limits.queuedArchiveBytes {
            throw APIError.insufficientStorage("queued archive bytes would exceed limit")
        }

        let id = JobID.generate()
        let now = Date()
        let config = req.application.gegenlesenConfig
        let title = nonempty(meta.title) ?? parsed.filename
        let job = Job(
            id: id,
            createdAt: now,
            updatedAt: now,
            status: .queued,
            scope: meta.scope,
            parentJobID: meta.parentJobID,
            title: title,
            repository: RepositoryName.normalize(meta.repository),
            reviewerAEngine: config.models.engineA,
            reviewerAModelID: config.models.modelA,
            reviewerBEngine: config.models.engineB,
            reviewerBModelID: config.models.modelB,
            judgeEngine: config.judgeEngine,
            judgeModelID: config.judgeModel,
            baseSHA: nonempty(meta.baseSHA),
            headSHA: nonempty(meta.headSHA),
            archiveSHA256: ContentHash.sha256(parsed.archive),
            archiveBytes: parsed.archive.count
        )

        let blobs = req.application.gegenlesenStore.blobs
        try blobs.ensureLayout()
        try parsed.archive.write(to: blobs.archiveURL(jobID: id.rawValue))
        if let patch = parsed.patch, !patch.isEmpty {
            try patch.write(to: blobs.patchURL(jobID: id.rawValue))
        }
        let identify = IdentifyMetaFile(
            baseSHA: nonempty(meta.baseSHA),
            headSHA: nonempty(meta.headSHA),
            baseRef: nonempty(meta.baseRef),
            headRef: nonempty(meta.headRef),
            parentHeadSHA: parentHeadSHA
        )
        try JSONEncoder().encode(identify).write(to: blobs.identifyMetaURL(jobID: id.rawValue))

        try await req.application.gegenlesenStore.insertJob(job)
        try await req.application.gegenlesenStore.appendEvent(jobID: id, level: .info, message: "queued")
        try await req.application.gegenlesenJobs.pushReview(id)

        let position = try await req.application.gegenlesenStore.queuePosition(createdAt: now)
        let body = JobAccepted(id: id, status: .queued, queuePosition: max(position, 1))
        return try encoded(body, status: .accepted, on: req)
    }

    static func list(_ req: Request) async throws -> JobListResponse {
        var limit = req.query[Int.self, at: "limit"] ?? 50
        if limit < 1 { limit = 1 }
        if limit > 200 { limit = 200 }
        let offset = max(req.query[Int.self, at: "offset"] ?? 0, 0)
        let status: JobStatus?
        if let raw = req.query[String.self, at: "status"] {
            guard let parsed = JobStatus(rawValue: raw) else {
                throw APIError.badRequest("invalid status")
            }
            status = parsed
        } else {
            status = nil
        }
        let active = try parseFlag(req, "active")
        let unscoped = try parseFlag(req, "unscoped")
        let repository = RepositoryName.normalize(req.query[String.self, at: "repository"])
        let query = nonempty(req.query[String.self, at: "q"])
        let page = try await req.application.gegenlesenStore.listJobs(
            limit: limit,
            offset: offset,
            status: status,
            active: active,
            repository: unscoped ? nil : repository,
            unscoped: unscoped || (req.query[String.self, at: "repository"] == "global"),
            query: query
        )
        var items: [JobListItem] = []
        items.reserveCapacity(page.jobs.count)
        for job in page.jobs {
            let position = try await req.application.gegenlesenStore.queuePosition(for: job)
            let summary = try await req.application.gegenlesenStore.summary(jobID: job.id)
            items.append(JobListItem.from(job, queuePosition: position, summary: summary))
        }
        return JobListResponse(jobs: items, total: page.total)
    }

    static func repositories(_ req: Request) async throws -> RepositoryListResponse {
        RepositoryListResponse(repositories: try await req.application.gegenlesenStore.listRepositories())
    }

    static func detail(_ req: Request) async throws -> JobDetail {
        let job = try await requireJob(req)
        return try await jobDetail(job, store: req.application.gegenlesenStore)
    }

    static func events(_ req: Request) async throws -> JobEventsResponse {
        let job = try await requireJob(req)
        let events = try await req.application.gegenlesenStore.events(jobID: job.id)
        return JobEventsResponse(events: events.map(JobEventDTO.init(event:)))
    }

    static func transcript(_ req: Request) async throws -> Response {
        let job = try await requireJob(req)
        guard let phase = req.query[String.self, at: "phase"], !phase.isEmpty else {
            throw APIError.badRequest("phase is required")
        }
        let candidates = transcriptPhases(phase)
        guard !candidates.isEmpty else {
            throw APIError.badRequest("invalid phase")
        }
        let blobs = req.application.gegenlesenStore.blobs
        let fm = FileManager.default
        var url: URL?
        for name in candidates {
            let candidate = blobs.transcriptURL(jobID: job.id.rawValue, phase: name)
            if fm.fileExists(atPath: candidate.path) {
                url = candidate
                break
            }
        }
        guard let url else {
            throw APIError.notFound("transcript not found")
        }
        let raw = try Data(contentsOf: url)
        let redacted = SecretRedactor().redact(raw)
        var headers = HTTPHeaders()
        headers.contentType = HTTPMediaType(type: "application", subType: "x-ndjson")
        return Response(status: .ok, headers: headers, body: .init(data: redacted))
    }

    static func feedback(_ req: Request) async throws -> FindingFeedbackListResponse {
        let job = try await requireJob(req)
        let rows = try await req.application.gegenlesenStore.feedback(jobID: job.id)
        return FindingFeedbackListResponse(feedback: rows.map(FindingFeedbackDTO.init(feedback:)))
    }

    static func cancel(_ req: Request) async throws -> JobDetail {
        let job = try await requireJob(req)
        if job.status.isTerminal {
            throw APIError.conflict("job is already \(job.status.rawValue)")
        }
        _ = try await req.application.gegenlesenStore.apply(jobID: job.id, event: .cancel)
        await req.application.gegenlesenJobs.cancel(job.id)
        let docker = req.application.gegenlesenDocker
        var names = Set(ReviewContainers.all(job.id))
        if let name = job.containerName { names.insert(name) }
        if let name = job.containerNameA { names.insert(name) }
        if let name = job.containerNameB { names.insert(name) }
        for name in names {
            await docker.kill(containerName: name)
        }
        await docker.removeAll(prefix: ReviewContainers.commandPrefix(job.id))
        try await req.application.gegenlesenStore.appendEvent(jobID: job.id, level: .info, message: "cancelled")
        guard let updated = try await req.application.gegenlesenStore.job(id: job.id) else {
            throw APIError.notFound()
        }
        return try await jobDetail(updated, store: req.application.gegenlesenStore)
    }

    static func riskLabel(_ req: Request) async throws -> JobDetail {
        let job = try await requireJob(req)
        guard job.status == .succeeded else {
            throw APIError.conflict("risk labels require a succeeded job")
        }
        guard var assessment = job.risk else {
            throw APIError.conflict("job has no risk assessment")
        }
        let body: RiskLabelRequest
        do {
            body = try req.content.decode(RiskLabelRequest.self)
        } catch {
            throw APIError.badRequest("invalid risk-label payload")
        }
        assessment.safeUnread = body.safeUnread
        try await req.application.gegenlesenStore.updateJobRisk(jobID: job.id, assessment: assessment)
        try await req.application.gegenlesenStore.appendEvent(
            jobID: job.id,
            level: .info,
            message: body.safeUnread ? "risk_label_safe" : "risk_label_unsafe"
        )
        if !body.safeUnread, assessment.verdict == .autoApprove {
            var config = req.application.gegenlesenConfig
            if config.risk.mode == .enforce {
                config.risk.mode = .shadow
                if let url = req.application.gegenlesenConfigFileURL {
                    try config.persist(to: url)
                }
                req.application.gegenlesenConfig = config
                req.application.gegenlesenJobs.apply(config)
                try await req.application.gegenlesenStore.appendEvent(
                    jobID: job.id,
                    level: .warning,
                    message: "risk_mode_shadow"
                )
            }
        }
        guard let updated = try await req.application.gegenlesenStore.job(id: job.id) else {
            throw APIError.notFound()
        }
        return try await jobDetail(updated, store: req.application.gegenlesenStore)
    }

    static func learn(_ req: Request) async throws -> Response {
        let job = try await requireJob(req)
        let id = try await req.application.gegenlesenJobs.enqueueLearn(sourceJobID: job.id)
        return try encoded(MineAccepted(jobID: id), status: .accepted, on: req)
    }

    private static func requireJob(_ req: Request) async throws -> Job {
        guard let raw = req.parameters.get("id") else {
            throw APIError.notFound()
        }
        guard let job = try await req.application.gegenlesenStore.job(id: JobID(raw)) else {
            throw APIError.notFound()
        }
        return job
    }

    private static func jobDetail(_ job: Job, store: Store) async throws -> JobDetail {
        let position = try await store.queuePosition(for: job)
        let summary = try await store.summary(jobID: job.id)
        let findings = try await store.findings(jobID: job.id)
        let events = try await store.events(jobID: job.id)
        return JobDetail.from(
            job,
            queuePosition: position,
            summary: summary,
            findings: findings,
            events: events
        )
    }

    private static func decodeMeta(_ data: Data) throws -> CreateJobMeta {
        do {
            return try JSONDecoder().decode(CreateJobMeta.self, from: data)
        } catch {
            throw APIError.badRequest("meta is not valid JSON")
        }
    }

    private static func parseMultipart(
        _ req: Request,
        archiveLimit: Int
    ) throws -> (archive: Data, filename: String, meta: Data, patch: Data?) {
        struct Parts: Content {
            var archive: File?
            var meta: File?
            var patch: File?
            var metaText: String?

            enum CodingKeys: String, CodingKey {
                case archive, meta, patch
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                archive = try container.decodeIfPresent(File.self, forKey: .archive)
                patch = try container.decodeIfPresent(File.self, forKey: .patch)
                if let file = try? container.decode(File.self, forKey: .meta) {
                    meta = file
                    metaText = nil
                } else {
                    meta = nil
                    metaText = try container.decodeIfPresent(String.self, forKey: .meta)
                }
            }
        }

        let parts: Parts
        do {
            parts = try req.content.decode(Parts.self)
        } catch {
            throw APIError.badRequest("missing archive/meta")
        }
        guard let archiveFile = parts.archive else {
            throw APIError.badRequest("missing archive")
        }
        let metaData: Data
        if let text = parts.metaText {
            guard let data = text.data(using: .utf8) else {
                throw APIError.badRequest("meta is not valid JSON")
            }
            metaData = data
        } else if let file = parts.meta {
            metaData = Data(buffer: file.data)
        } else {
            throw APIError.badRequest("missing meta")
        }

        let filename = archiveFile.filename
        let contentType = archiveFile.contentType?.serialize() ?? ""
        if filename.lowercased().hasSuffix(".zip") || contentType.contains("zip") {
            throw APIError.unsupportedMediaType("zip archives are not accepted")
        }

        let archive = Data(buffer: archiveFile.data)
        if archive.count > archiveLimit {
            throw APIError.payloadTooLarge("archive exceeds archive_bytes")
        }
        if archive.count >= 2, archive[0] == 0x50, archive[1] == 0x4B {
            throw APIError.unsupportedMediaType("zip archives are not accepted")
        }

        let patch = parts.patch.map { Data(buffer: $0.data) }
        return (archive, filename, metaData, patch)
    }

    private static func encoded<T: Content>(_ body: T, status: HTTPResponseStatus, on req: Request) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        let data = try JSONCoding.encoder.encode(body)
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    private static func parseFlag(_ req: Request, _ name: String) throws -> Bool {
        guard let raw = req.query[String.self, at: name] else { return false }
        switch raw.lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: throw APIError.badRequest("invalid \(name)")
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func transcriptPhases(_ phase: String) -> [String] {
        switch phase {
        case "review_a", "review_b":
            return [phase, "review"]
        case "review", "judge", "mine", "suggestion_judge":
            return [phase]
        default:
            return []
        }
    }
}
