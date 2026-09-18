import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GegenlesenCore

struct JevFindingJudge: FastJudgeRunning {
    let apiKey: String
    let model: String
    let minConfidence: Double
    let timeout: TimeInterval
    var endpoint = URL(string: "https://openrouter.ai/api/alpha/decisions")!
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    func run(_ input: JudgeInputFile) async -> JudgeOutcome {
        let candidates = input.candidates.filter(\.evidenceOK)
        guard !apiKey.isEmpty, !candidates.isEmpty else {
            return .verdicts(JudgeFile(verdicts: []))
        }
        let results = await withTaskGroup(of: [JudgeVerdictRow]?.self, returning: [[JudgeVerdictRow]].self) { group in
            for candidate in candidates {
                group.addTask {
                    await judge(candidate)
                }
            }
            var collected: [[JudgeVerdictRow]] = []
            for await rows in group {
                guard let rows else { continue }
                collected.append(rows)
            }
            return collected
        }
        guard results.count == candidates.count else {
            return .containerFailed
        }
        return .verdicts(JudgeFile(verdicts: results.flatMap { $0 }))
    }

    private func judge(_ candidate: JudgeCandidate) async -> [JudgeVerdictRow]? {
        let state: [String: Any] = [
            "finding": [
                "title": candidate.title,
                "message": candidate.message,
                "rationale": candidate.rationale ?? "",
                "file_path": candidate.filePath,
                "start_line": candidate.startLine,
                "end_line": candidate.endLine,
                "snippet": candidate.snippet,
                "source_context": candidate.actualSlice,
            ],
        ]
        let questions: [String: Any] = [
            "evidence": [
                "type": "choice",
                "instructions": "Does the source context support the finding's claimed concrete defect?",
                "criteria": [
                    "supported": "The cited source context demonstrates the specific defect claimed by the finding.",
                    "unsupported": "The cited source context does not demonstrate the specific defect claimed by the finding.",
                ],
            ],
            "actionability": [
                "type": "choice",
                "instructions": "Should this finding be kept as an actionable PR review issue based only on the finding and source context?",
                "criteria": [
                    "actionable": "It identifies a concrete bug, security issue, regression, contract break, or missing test supported by the source context.",
                    "not_actionable": "It is speculative, stylistic, unsupported, or does not identify a concrete issue in the source context.",
                ],
            ],
        ]
        let body: [String: Any] = [
            "model": model,
            "state": state,
            "questions": questions,
        ]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://gegenlesen.local", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("gegenlesen", forHTTPHeaderField: "X-Title")
        do {
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let answer = try? JSONDecoder().decode(JevResponse.self, from: data),
                  let evidence = answer.answers["evidence"],
                  let actionability = answer.answers["actionability"]
            else {
                return nil
            }
            guard evidence.choice == "unsupported",
                  actionability.choice == "not_actionable",
                  evidence.confidence >= minConfidence,
                  actionability.confidence >= minConfidence
            else {
                return []
            }
            let rationale = String(
                format: "jev: unsupported (%.2f) and not actionable (%.2f)",
                evidence.confidence,
                actionability.confidence
            )
            return [JudgeVerdictRow(findingID: candidate.id, verdict: .drop, rationale: rationale)]
        } catch {
            return nil
        }
    }
}

private struct JevResponse: Decodable {
    var answers: [String: Answer]

    struct Answer: Decodable {
        var choice: String
        var confidence: Double {
            confidenceValue ?? probabilities?[choice] ?? 0
        }
        var confidenceValue: Double?
        var probabilities: [String: Double]?

        enum CodingKeys: String, CodingKey {
            case choice, confidenceValue = "confidence", probabilities
        }
    }
}
