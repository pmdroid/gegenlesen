import Foundation
import MeisterCore
import Vapor

enum FindingsRoute {
    static func register(_ app: Application) {
        app.post("api", "findings", ":id", "feedback", use: createFeedback)
    }

    static func createFeedback(_ req: Request) async throws -> Response {
        guard let raw = req.parameters.get("id") else {
            throw APIError.notFound()
        }
        let store = req.application.meisterStore
        guard let finding = try await store.finding(id: FindingID(raw)) else {
            throw APIError.notFound()
        }
        let body: FindingFeedbackRequest
        do {
            body = try req.content.decode(FindingFeedbackRequest.self)
        } catch {
            throw APIError.badRequest("invalid feedback payload")
        }

        let reaction: FeedbackReaction?
        if let rawReaction = body.reaction {
            guard let parsed = FeedbackReaction.normalize(rawReaction) else {
                throw APIError.badRequest("unknown reaction")
            }
            reaction = parsed
        } else {
            reaction = nil
        }

        let verdict: FeedbackVerdict
        if let reaction {
            verdict = reaction.verdict
        } else if let requested = body.verdict {
            verdict = requested
        } else {
            throw APIError.badRequest("verdict or reaction is required")
        }

        let comment = nonempty(body.comment)
        if verdict == .comment && comment == nil {
            throw APIError.badRequest("comment is required")
        }

        if let reaction {
            let existing = try await store.feedback(findingID: finding.id)
            if let current = existing.reversed().first(where: { $0.verdict == .agree || $0.verdict == .disagree }),
               current.reaction == reaction {
                try await store.deleteFeedback(id: current.id)
                return try encoded(FindingFeedbackDTO(feedback: current), status: .created, on: req)
            }
        }

        let row = try await store.recordFindingFeedback(
            finding: finding,
            verdict: verdict,
            reaction: reaction,
            comment: comment
        )
        return try encoded(FindingFeedbackDTO(feedback: row), status: .created, on: req)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func encoded<T: Content>(_ body: T, status: HTTPResponseStatus, on req: Request) throws -> Response {
        var headers = HTTPHeaders()
        headers.contentType = .json
        let data = try JSONCoding.encoder.encode(body)
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}
