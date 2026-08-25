import Foundation
import GegenlesenCore
import Vapor

enum LearningsRoute {
    static func register(_ app: Application) {
        app.get("api", "learnings", use: list)
        app.post("api", "learnings", ":id", "accept", use: accept)
        app.post("api", "learnings", ":id", "dismiss", use: dismiss)
        app.post("api", "learnings", ":id", "restore", use: restore)
    }

    static func list(_ req: Request) async throws -> LearningListResponse {
        let status: LearningStatus?
        if let raw = req.query[String.self, at: "status"] {
            guard let parsed = LearningStatus(rawValue: raw) else {
                throw APIError.badRequest("invalid status")
            }
            status = parsed
        } else {
            status = .pending
        }
        let kind: LearningKind?
        if let raw = req.query[String.self, at: "kind"] {
            guard let parsed = LearningKind(rawValue: raw) else {
                throw APIError.badRequest("invalid kind")
            }
            kind = parsed
        } else {
            kind = nil
        }
        let store = req.application.gegenlesenStore
        let items = try await store.listLearnings(status: status, kind: kind)
        let all = try await store.listLearnings(status: nil, kind: kind)
        return LearningListResponse(
            learnings: items.map(LearningDTO.init(learning:)),
            yield: LearningDedup.yield(from: all).map(LearningYieldDTO.init(yield:))
        )
    }

    static func accept(_ req: Request) async throws -> LearningDTO {
        var item = try await requireLearning(req)
        if item.status != .pending {
            throw APIError.conflict("learning is already \(item.status.rawValue)")
        }
        switch item.kind {
        case .rule:
            try await acceptRule(item, on: req)
        case .architecture:
            try await acceptArchitecture(item, on: req)
        case .context:
            try await acceptContext(item, on: req)
        }
        item.status = .accepted
        item.resolvedAt = Date()
        try await req.application.gegenlesenStore.updateLearning(item)
        return LearningDTO(learning: item)
    }

    static func dismiss(_ req: Request) async throws -> LearningDTO {
        var item = try await requireLearning(req)
        if item.status != .pending && item.status != .needsRejudge {
            throw APIError.conflict("learning is already \(item.status.rawValue)")
        }
        let body = try decodeDismiss(req)
        item.applyDismiss(reason: body.reason, comment: body.comment)
        item.status = .dismissed
        item.resolvedAt = Date()
        try await req.application.gegenlesenStore.updateLearning(item)
        return LearningDTO(learning: item)
    }

    static func restore(_ req: Request) async throws -> LearningDTO {
        var item = try await requireLearning(req)
        if item.status == .needsRejudge {
            item.status = .pending
            item.resolvedAt = nil
            try await req.application.gegenlesenStore.updateLearning(item)
            return LearningDTO(learning: item)
        }
        if item.status != .dismissed {
            throw APIError.conflict("learning is already \(item.status.rawValue)")
        }
        item.clearDismiss()
        item.status = .pending
        item.resolvedAt = nil
        try await req.application.gegenlesenStore.updateLearning(item)
        return LearningDTO(learning: item)
    }

    private static func acceptRule(_ item: Learning, on req: Request) async throws {
        let store = req.application.gegenlesenStore
        let repository = try await sourceRepository(item, store: store)
        if let ruleID = payloadString(item.payloadJSON, key: "rule_id") {
            let id = RuleID(ruleID)
            if let existing = try await store.rule(id: id), existing.deletedAt == nil {
                if existing.provenance != .handwritten {
                    var promoted = RulePromotion.promoteInPlace(existing)
                    if promoted.repository == nil {
                        promoted.repository = repository
                    }
                    try await store.updateRule(promoted)
                    await embedRule(promoted, on: req)
                }
                return
            }
        }
        let now = Date()
        let rule = Rule(
            id: RuleID.slug(from: item.title),
            title: item.title,
            severity: .warning,
            kind: .semantic,
            enabled: true,
            provenance: .handwritten,
            languages: ["*"],
            pathGlobs: ["**/*"],
            repository: repository,
            payload: .semantic(instruction: item.body, fewShots: []),
            body: item.body,
            createdAt: now,
            updatedAt: now
        )
        let outcome = try await MinerDedup.upsert(rule, into: store, now: now)
        let storedID: RuleID
        switch outcome {
        case .inserted(let id), .attached(let id):
            storedID = id
        }
        if var stored = try await store.rule(id: storedID) {
            stored.enabled = true
            stored.provenance = .handwritten
            stored.updatedAt = now
            try await store.updateRule(stored)
            await embedRule(stored, on: req)
        }
    }

    private static func embedRule(_ rule: Rule, on req: Request) async {
        try? await ArchitectureIndexJob(
            store: req.application.gegenlesenStore,
            embedder: req.application.gegenlesenEmbedder
        ).embedRule(rule)
    }

    private static func acceptArchitecture(_ item: Learning, on req: Request) async throws {
        let store = req.application.gegenlesenStore
        let now = Date()
        let repository = try await sourceRepository(item, store: store)
        if var existing = try await store.acceptedArchitectureNote(repository: repository) {
            existing.title = item.title
            existing.body = item.body
            existing.updatedAt = now
            try await store.updateContextNote(existing)
            await reembed(existing, on: req)
        } else {
            let note = ContextNote(
                kind: .architecture,
                title: item.title,
                body: item.body,
                repository: repository,
                createdAt: now,
                updatedAt: now
            )
            try await store.insertContextNote(note)
            await reembed(note, on: req)
        }
    }

    private static func acceptContext(_ item: Learning, on req: Request) async throws {
        let repository = try await sourceRepository(item, store: req.application.gegenlesenStore)
        let note = ContextNote(title: item.title, body: item.body, repository: repository)
        try await req.application.gegenlesenStore.insertContextNote(note)
        await reembed(note, on: req)
    }

    private static func sourceRepository(_ item: Learning, store: Store) async throws -> String? {
        guard let jobID = item.jobID else { return nil }
        return try await store.job(id: jobID)?.repository
    }

    private static func reembed(_ note: ContextNote, on req: Request) async {
        try? await ArchitectureIndexJob(
            store: req.application.gegenlesenStore,
            embedder: req.application.gegenlesenEmbedder
        ).embedNote(note)
    }

    private static func payloadString(_ raw: String?, key: String) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    private static func decodeDismiss(_ req: Request) throws -> (reason: LearningDismissReason?, comment: String?) {
        let collected = req.body.data?.readableBytes ?? 0
        if collected == 0 && req.headers.contentType == nil {
            return (nil, nil)
        }
        let body: LearningDismissRequest
        do {
            body = try req.content.decode(LearningDismissRequest.self)
        } catch {
            throw APIError.badRequest("invalid dismiss payload")
        }
        let reason: LearningDismissReason?
        if let raw = nonempty(body.reason) {
            guard let parsed = LearningDismissReason(rawValue: raw) else {
                throw APIError.badRequest("invalid dismiss reason")
            }
            reason = parsed
        } else {
            reason = nil
        }
        return (reason, nonempty(body.comment))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func requireLearning(_ req: Request) async throws -> Learning {
        guard let raw = req.parameters.get("id") else {
            throw APIError.notFound()
        }
        guard let item = try await req.application.gegenlesenStore.learning(id: raw) else {
            throw APIError.notFound()
        }
        return item
    }
}

enum MetricsRoute {
    static func register(_ app: Application) {
        app.get("api", "metrics", use: metrics)
    }

    static func metrics(_ req: Request) async throws -> Response {
        if !isLoopback(req) {
            throw APIError.forbidden("metrics are localhost-only")
        }
        let snap = try await req.application.gegenlesenStore.metricsSnapshot()
        var lines: [String] = [
            "# HELP gegenlesen_queue_depth Jobs with status=queued",
            "# TYPE gegenlesen_queue_depth gauge",
            "gegenlesen_queue_depth \(snap.queueDepth)",
            "# TYPE gegenlesen_jobs_total counter",
        ]
        if snap.jobsByStatusScope.isEmpty {
            lines.append("gegenlesen_jobs_total{status=\"queued\",scope=\"full\"} 0")
        } else {
            for key in snap.jobsByStatusScope.keys.sorted() {
                let parts = key.split(separator: "|", omittingEmptySubsequences: false)
                let status = parts.first.map(String.init) ?? ""
                let scope = parts.count > 1 ? String(parts[1]) : ""
                let n = snap.jobsByStatusScope[key] ?? 0
                lines.append("gegenlesen_jobs_total{status=\"\(status)\",scope=\"\(scope)\"} \(n)")
            }
        }
        lines.append("# TYPE gegenlesen_job_duration_seconds gauge")
        for phase in ["unpack", "identify", "deterministic", "review", "judge"] {
            let value = snap.durationSeconds[phase] ?? 0
            lines.append("gegenlesen_job_duration_seconds{phase=\"\(phase)\"} \(format(value))")
        }
        lines.append("# TYPE gegenlesen_findings_total counter")
        if snap.findingsByKey.isEmpty {
            lines.append("gegenlesen_findings_total{phase=\"agent\",verdict=\"none\",severity=\"info\"} 0")
        } else {
            for key in snap.findingsByKey.keys.sorted() {
                let parts = key.split(separator: "|", omittingEmptySubsequences: false)
                let phase = parts.first.map(String.init) ?? ""
                let verdict = parts.count > 1 ? String(parts[1]) : "none"
                let severity = parts.count > 2 ? String(parts[2]) : ""
                let n = snap.findingsByKey[key] ?? 0
                lines.append(
                    "gegenlesen_findings_total{phase=\"\(phase)\",verdict=\"\(verdict)\",severity=\"\(severity)\"} \(n)"
                )
            }
        }
        lines.append("# TYPE gegenlesen_docker_oom_total counter")
        lines.append("gegenlesen_docker_oom_total \(snap.dockerOOMTotal)")
        lines.append("# TYPE gegenlesen_archive_bytes gauge")
        lines.append("gegenlesen_archive_bytes \(snap.archiveBytes)")
        lines.append("")
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/plain; version=0.0.4; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: lines.joined(separator: "\n")))
    }

    static func isLoopbackAddress(_ address: String?) -> Bool {
        guard let address else { return true }
        if address == "127.0.0.1" || address == "::1" || address == "0:0:0:0:0:0:0:1" {
            return true
        }
        if address == "::ffff:127.0.0.1" || address.hasPrefix("::ffff:127.") {
            return true
        }
        return false
    }

    private static func isLoopback(_ req: Request) -> Bool {
        isLoopbackAddress(req.remoteAddress?.ipAddress)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
