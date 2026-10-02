import Foundation
import GegenlesenCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct GegenlesenClient: Sendable {
    var baseURL: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let raw = environment["GEGENLESEN_URL"] ?? "http://127.0.0.1:8080"
        self.baseURL = URL(string: raw) ?? URL(string: "http://127.0.0.1:8080")!
    }

    func createJob(archive: Data, meta: [String: Any]) async throws -> AcceptedJSON {
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        let boundary = "gegenlesen-\(UUID().uuidString)"
        var body = Data()
        append(&body, "--\(boundary)\r\n")
        append(&body, "Content-Disposition: form-data; name=\"archive\"; filename=\"change.tar.gz\"\r\n")
        append(&body, "Content-Type: application/gzip\r\n\r\n")
        body.append(archive)
        append(&body, "\r\n--\(boundary)\r\n")
        append(&body, "Content-Disposition: form-data; name=\"meta\"\r\n")
        append(&body, "Content-Type: application/json\r\n\r\n")
        body.append(metaData)
        append(&body, "\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: baseURL.appendingPathComponent("api/jobs"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        if let deadline = ReviewDeadline.expiresAt {
            try ReviewDeadline.check()
            let remaining = (deadline - ContinuousClock.now).timeInterval
            request.timeoutInterval = ceil(max(1, remaining))
            request.setValue(String(Date().addingTimeInterval(remaining).timeIntervalSince1970), forHTTPHeaderField: "X-Gegenlesen-Deadline")
        }
        let preparedRequest = request
        let (data, response) = try await ReviewDeadline.run(timeout: .seconds(ReviewDeadline.maximumSeconds)) {
            try await URLSession.shared.data(for: preparedRequest)
        }
        try throwIfNeeded(data: data, response: response, expected: 202)
        return try JSONDecoder().decode(AcceptedJSON.self, from: data)
    }

    func createHarvest(archive: Data, repository: String? = nil) async throws -> AcceptedJSON {
        let boundary = "gegenlesen-\(UUID().uuidString)"
        var body = Data()
        append(&body, "--\(boundary)\r\n")
        append(&body, "Content-Disposition: form-data; name=\"archive\"; filename=\"tree.tar.gz\"\r\n")
        append(&body, "Content-Type: application/gzip\r\n\r\n")
        body.append(archive)
        if let repository {
            append(&body, "\r\n--\(boundary)\r\n")
            append(&body, "Content-Disposition: form-data; name=\"repository\"\r\n\r\n")
            append(&body, repository)
        }
        append(&body, "\r\n--\(boundary)--\r\n")
        var request = URLRequest(url: baseURL.appendingPathComponent("api/harvest"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(data: data, response: response, expected: 202)
        return try JSONDecoder().decode(AcceptedJSON.self, from: data)
    }

    func jobs() async throws -> JobListJSON {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/jobs"))
        try throwIfNeeded(data: data, response: response, expected: 200)
        return try JSONDecoder().decode(JobListJSON.self, from: data)
    }

    func job(id: String) async throws -> JobJSON {
        try ReviewDeadline.check()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/jobs/\(id)"))
        request.timeoutInterval = 30
        let preparedRequest = request
        let (data, response) = try await ReviewDeadline.run(timeout: .seconds(30)) {
            try await URLSession.shared.data(for: preparedRequest)
        }
        try throwIfNeeded(data: data, response: response, expected: 200)
        return try JSONDecoder().decode(JobJSON.self, from: data)
    }

    func cancel(id: String) async throws -> JobJSON {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/jobs/\(id)/cancel"))
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfNeeded(data: data, response: response, expected: 200)
        return try JSONDecoder().decode(JobJSON.self, from: data)
    }

    func poll(id: String, timeout: TimeInterval = 1800, progress: Bool = false) async throws -> JobJSON {
        let started = ContinuousClock.now
        let deadline = min(ReviewDeadline.expiresAt ?? started + .seconds(timeout), started + .seconds(timeout))
        return try await ReviewDeadline.$expiresAt.withValue(deadline) {
            var lastStatus: String?
            var lastProgress = started - .seconds(10)
            do {
                while ContinuousClock.now < deadline {
                    let job = try await job(id: id)
                    if progress {
                        if lastStatus == nil {
                            let models = "A \(job.reviewerAEngine ?? "")/\(job.reviewerAModelID ?? "unknown"), B \(job.reviewerBEngine ?? "")/\(job.reviewerBModelID ?? "unknown"), judge \(job.judgeEngine ?? "")/\(job.judgeModelID ?? "unknown")"
                            FileHandle.standardError.write(Data("models requested: \(models)\n".utf8))
                        }
                        if lastStatus != job.status || ContinuousClock.now - lastProgress >= .seconds(10) {
                            let queue = job.queuePosition.map { " · queue \($0)" } ?? ""
                            FileHandle.standardError.write(Data("\(job.status)\(queue) · \(Int((ContinuousClock.now - started).timeInterval))s waiting\n".utf8))
                            lastProgress = ContinuousClock.now
                        }
                        lastStatus = job.status
                    }
                    if ["succeeded", "failed", "cancelled"].contains(job.status) { return job }
                    try await Task.sleep(for: ReviewDeadline.timeout(.seconds(1)))
                }
            } catch {
                if ContinuousClock.now < deadline { throw error }
            }
            throw CLIError("review_deadline_exceeded: job \(id) is incomplete; check its status with gegenlesen status \(id)")
        }
    }

    private func throwIfNeeded(data: Data, response: URLResponse, expected: Int) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == expected { return }
        if let envelope = try? JSONDecoder().decode(ErrorJSON.self, from: data) {
            throw CLIError("HTTP \(status) \(envelope.error.code): \(envelope.error.message)")
        }
        throw CLIError("HTTP \(status)")
    }
}

struct AcceptedJSON: Decodable {
    var id: String
    var status: String
    var queuePosition: Int

    enum CodingKeys: String, CodingKey {
        case id, status
        case queuePosition = "queue_position"
    }
}

struct JobListJSON: Decodable {
    var jobs: [JobJSON]
    var total: Int
}

struct JobJSON: Decodable {
    var id: String
    var title: String?
    var status: String
    var headSHA: String?
    var baseSHA: String?
    var repository: String?
    var errorMessage: String?
    var risk: RiskJSON?
    var queuePosition: Int?
    var reviewerAEngine: String?
    var reviewerAModelID: String?
    var reviewerBEngine: String?
    var reviewerBModelID: String?
    var judgeEngine: String?
    var judgeModelID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status
        case headSHA = "head_sha"
        case baseSHA = "base_sha"
        case repository
        case errorMessage = "error_message"
        case queuePosition = "queue_position"
        case reviewerAEngine = "reviewer_a_engine"
        case reviewerAModelID = "reviewer_a_model_id"
        case reviewerBEngine = "reviewer_b_engine"
        case reviewerBModelID = "reviewer_b_model_id"
        case judgeEngine = "judge_engine"
        case judgeModelID = "judge_model_id"
        case risk
    }
}

struct RiskJSON: Decodable {
    var verdict: String
    var mode: String
    var score: Int?
    var appetite: Int?
    var reasons: [Reason]
    var safeUnread: Bool?

    struct Reason: Decodable {
        var code: String
        var detail: String
        var points: Int?
    }

    enum CodingKeys: String, CodingKey {
        case verdict, mode, score, appetite, reasons
        case safeUnread = "safe_unread"
    }
}

struct ErrorJSON: Decodable {
    var error: Body
    struct Body: Decodable {
        var code: String
        var message: String
    }
}

private func append(_ data: inout Data, _ string: String) {
    data.append(Data(string.utf8))
}
