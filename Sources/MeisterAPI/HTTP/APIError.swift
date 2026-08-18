import MeisterCore
import Vapor

struct APIError: Error, AbortError, DebuggableError {
    var status: HTTPResponseStatus
    var code: ErrorCode
    var message: String
    var details: [String: String]?

    var reason: String { message }

    init(
        status: HTTPResponseStatus,
        code: ErrorCode,
        message: String,
        details: [String: String]? = nil
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
    }

    static func badRequest(_ message: String, details: [String: String]? = nil) -> APIError {
        APIError(status: .badRequest, code: .badRequest, message: message, details: details)
    }

    static func notFound(_ message: String = "not found") -> APIError {
        APIError(status: .notFound, code: .notFound, message: message)
    }

    static func conflict(_ message: String) -> APIError {
        APIError(status: .conflict, code: .conflict, message: message)
    }

    static func payloadTooLarge(_ message: String) -> APIError {
        APIError(status: .payloadTooLarge, code: .payloadTooLarge, message: message)
    }

    static func unsupportedMediaType(_ message: String) -> APIError {
        APIError(status: .unsupportedMediaType, code: .unsupportedMediaType, message: message)
    }

    static func unprocessable(_ message: String, details: [String: String]? = nil) -> APIError {
        APIError(status: .unprocessableEntity, code: .unprocessable, message: message, details: details)
    }

    static func insufficientStorage(_ message: String) -> APIError {
        APIError(
            status: .custom(code: 507, reasonPhrase: "Insufficient Storage"),
            code: .insufficientStorage,
            message: message
        )
    }
}

struct APIErrorBody: Content {
    var error: Payload

    struct Payload: Content {
        var code: String
        var message: String
        var details: [String: String]?

        enum CodingKeys: String, CodingKey {
            case code, message, details
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
            if let details {
                try container.encode(details, forKey: .details)
            }
        }
    }

    init(_ error: APIError) {
        self.error = Payload(code: error.code.rawValue, message: error.message, details: error.details)
    }
}

struct APIErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let error as APIError {
            return encoded(error, on: request)
        } catch let abort as AbortError {
            let mapped = mapAbort(abort)
            return encoded(mapped, on: request)
        } catch {
            return encoded(
                APIError(
                    status: .internalServerError,
                    code: .internal,
                    message: "internal"
                ),
                on: request
            )
        }
    }

    private func mapAbort(_ abort: AbortError) -> APIError {
        switch abort.status {
        case .payloadTooLarge:
            return .payloadTooLarge("payload too large")
        case .unsupportedMediaType:
            return .unsupportedMediaType("unsupported media type")
        case .notFound:
            return .notFound()
        case .badRequest:
            return .badRequest(abort.reason)
        default:
            let code: ErrorCode = abort.status.code >= 500 ? .internal : .badRequest
            return APIError(status: abort.status, code: code, message: abort.reason)
        }
    }

    private func encoded(_ error: APIError, on request: Request) -> Response {
        let response = Response(status: error.status)
        response.headers.contentType = .json
        if let data = try? JSONCoding.encoder.encode(APIErrorBody(error)) {
            response.body = .init(data: data)
        }
        return response
    }
}
