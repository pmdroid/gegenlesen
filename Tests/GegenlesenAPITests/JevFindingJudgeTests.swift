import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GegenlesenCore
import Testing
@testable import GegenlesenAPI

@Suite
struct JevFindingJudgeTests {
    @Test
    func dropsOnlyWhenBothLensesConfidentlyRejectTheFinding() async throws {
        let body = Data(
            """
            {"answers":{"evidence":{"choice":"unsupported","confidence":0.95},"actionability":{"choice":"not_actionable","confidence":0.93}}}
            """.utf8
        )
        let judge = JevFindingJudge(
            apiKey: "typesafe-test",
            model: "jev-latest",
            minConfidence: 0.9,
            timeout: 4,
            endpoint: URL(string: "https://example.test/v1/systemone")!,
            send: { _ in
                (body, HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let outcome = await judge.run(JudgeInputFile(candidates: [candidate()]))
        guard case .verdicts(let file) = outcome else {
            Issue.record("expected verdicts")
            return
        }
        #expect(file.verdicts.count == 1)
        #expect(file.verdicts[0].verdict == .drop)
        #expect(file.verdicts[0].rationale.contains("unsupported (0.95)"))
    }

    @Test
    func keepsFindingWhenEitherLensDoesNotRejectIt() async throws {
        let body = Data(
            """
            {"answers":{"evidence":{"choice":"unsupported","confidence":0.95},"actionability":{"choice":"actionable","confidence":0.93}}}
            """.utf8
        )
        let judge = JevFindingJudge(
            apiKey: "typesafe-test",
            model: "jev-latest",
            minConfidence: 0.9,
            timeout: 4,
            endpoint: URL(string: "https://example.test/v1/systemone")!,
            send: { _ in
                (body, HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let outcome = await judge.run(JudgeInputFile(candidates: [candidate()]))
        guard case .verdicts(let file) = outcome else {
            Issue.record("expected verdicts")
            return
        }
        #expect(file.verdicts.isEmpty)
    }

    private func candidate() -> JudgeCandidate {
        JudgeCandidate(
            id: FindingID("fnd_jev"),
            severity: .warning,
            title: "Claim",
            message: "The code fails.",
            filePath: "Sources/A.swift",
            startLine: 1,
            endLine: 1,
            snippet: "print(2)",
            phase: .agent,
            evidenceOK: true,
            actualSlice: "print(2)"
        )
    }
}
