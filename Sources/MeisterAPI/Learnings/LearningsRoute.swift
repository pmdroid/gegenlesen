import Foundation
import MeisterCore
import Vapor

enum LearningsRoute {
    static func register(_ app: Application) {
        app.get("api", "learnings", use: list)
        app.post("api", "learnings", ":id", "accept", use: accept)
        app.post("api", "learnings", ":id", "dismiss", use: dismiss)
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
        let items = try await req.application.meisterStore.listLearnings(status: status, kind: kind)
        return LearningListResponse(learnings: items.map(LearningDTO.init(learning:)))
    }

    static func accept(_ req: Request) async throws -> LearningDTO {
        var item = try await requireLearning(req)
        if item.status != .pending {
            throw APIError.conflict("learning is already \(item.status.rawValue)")
        }
        switch item.kind {
        case .rule:
            try await acceptRule(item, store: req.application.meisterStore)
        case .architecture:
            try await acceptArchitecture(item, on: req)
        case .context:
            try await acceptContext(item, on: req)
        }
        item.status = .accepted
        item.resolvedAt = Date()
        try await req.application.meisterStore.updateLearning(item)
        return LearningDTO(learning: item)
    }

    static func dismiss(_ req: Request) async throws -> LearningDTO {
        var item = try await requireLearning(req)
        if item.status != .pending {
            throw APIError.conflict("learning is already \(item.status.rawValue)")
        }
        item.status = .dismissed
        item.resolvedAt = Date()
        try await req.application.meisterStore.updateLearning(item)
        return LearningDTO(learning: item)
    }

    private static func acceptRule(_ item: Learning, store: Store) async throws {
        if let ruleID = payloadString(item.payloadJSON, key: "rule_id") {
            let id = RuleID(ruleID)
            if let existing = try await store.rule(id: id), existing.deletedAt == nil {
                if existing.provenance != .handwritten, try await store.rulePromotedFrom(existing.id) == nil {
                    let now = Date()
                    let copy = Rule(
                        id: RuleID(existing.id.rawValue + "-handwritten"),
                        title: existing.title,
                        severity: existing.severity,
                        kind: existing.kind,
                        enabled: true,
                        provenance: .handwritten,
                        languages: existing.languages,
                        pathGlobs: existing.pathGlobs,
                        payload: existing.payload,
                        examples: existing.examples,
                        sourcePRRefs: existing.sourcePRRefs,
                        promotedFromRuleID: existing.id,
                        body: existing.body,
                        createdAt: now,
                        updatedAt: now
                    )
                    var unique = copy
                    if try await store.rule(id: unique.id) != nil {
                        unique.id = RuleID(existing.id.rawValue + "-hw")
                    }
                    try await store.insertRule(unique)
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
            payload: .semantic(instruction: item.body, fewShots: []),
            body: item.body,
            createdAt: now,
            updatedAt: now
        )
        try await MinerDedup.upsert(rule, into: store, now: now)
    }

    private static func acceptArchitecture(_ item: Learning, on req: Request) async throws {
        let store = req.application.meisterStore
        let now = Date()
        if var existing = try await store.acceptedArchitectureNote() {
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
                createdAt: now,
                updatedAt: now
            )
            try await store.insertContextNote(note)
            await reembed(note, on: req)
        }
    }

    private static func acceptContext(_ item: Learning, on req: Request) async throws {
        let note = ContextNote(title: item.title, body: item.body)
        try await req.application.meisterStore.insertContextNote(note)
        await reembed(note, on: req)
    }

    private static func reembed(_ note: ContextNote, on req: Request) async {
        let config = req.application.meisterConfig
        let embedder = EmbeddingClientFactory.fromEnvironment(
            model: config.embeddings.model,
            dimensions: config.embeddings.dimensions
        )
        try? await ArchitectureIndexJob(
            store: req.application.meisterStore,
            embedder: embedder
        ).embedNote(note)
    }

    private static func payloadString(_ raw: String?, key: String) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    private static func requireLearning(_ req: Request) async throws -> Learning {
        guard let raw = req.parameters.get("id") else {
            throw APIError.notFound()
        }
        guard let item = try await req.application.meisterStore.learning(id: raw) else {
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
            throw Abort(.forbidden)
        }
        let snap = try await req.application.meisterStore.metricsSnapshot()
        var lines: [String] = [
            "# HELP meister_queue_depth Jobs with status=queued",
            "# TYPE meister_queue_depth gauge",
            "meister_queue_depth \(snap.queueDepth)",
            "# TYPE meister_jobs_total counter",
        ]
        if snap.jobsByStatusScope.isEmpty {
            lines.append("meister_jobs_total{status=\"queued\",scope=\"full\"} 0")
        } else {
            for key in snap.jobsByStatusScope.keys.sorted() {
                let parts = key.split(separator: "|", omittingEmptySubsequences: false)
                let status = parts.first.map(String.init) ?? ""
                let scope = parts.count > 1 ? String(parts[1]) : ""
                let n = snap.jobsByStatusScope[key] ?? 0
                lines.append("meister_jobs_total{status=\"\(status)\",scope=\"\(scope)\"} \(n)")
            }
        }
        lines.append("# TYPE meister_job_duration_seconds gauge")
        for phase in ["unpack", "identify", "deterministic", "review", "judge"] {
            let value = snap.durationSeconds[phase] ?? 0
            lines.append("meister_job_duration_seconds{phase=\"\(phase)\"} \(format(value))")
        }
        lines.append("# TYPE meister_findings_total counter")
        if snap.findingsByKey.isEmpty {
            lines.append("meister_findings_total{phase=\"agent\",verdict=\"none\",severity=\"info\"} 0")
        } else {
            for key in snap.findingsByKey.keys.sorted() {
                let parts = key.split(separator: "|", omittingEmptySubsequences: false)
                let phase = parts.first.map(String.init) ?? ""
                let verdict = parts.count > 1 ? String(parts[1]) : "none"
                let severity = parts.count > 2 ? String(parts[2]) : ""
                let n = snap.findingsByKey[key] ?? 0
                lines.append(
                    "meister_findings_total{phase=\"\(phase)\",verdict=\"\(verdict)\",severity=\"\(severity)\"} \(n)"
                )
            }
        }
        lines.append("# TYPE meister_docker_oom_total counter")
        lines.append("meister_docker_oom_total \(snap.dockerOOMTotal)")
        lines.append("# TYPE meister_archive_bytes gauge")
        lines.append("meister_archive_bytes \(snap.archiveBytes)")
        lines.append("")
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "text/plain; version=0.0.4; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: lines.joined(separator: "\n")))
    }

    private static func isLoopback(_ req: Request) -> Bool {
        guard let address = req.remoteAddress?.ipAddress else { return true }
        return address == "127.0.0.1" || address == "::1" || address == "0:0:0:0:0:0:0:1"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
