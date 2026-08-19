import Foundation
import Testing
@testable import GegenlesenCore
@testable import GegenlesenDeterministic

@Suite
struct EvalGoldenTests {
    @Test
    func ciCasesPassThroughPackAndDeterministicEngine() async throws {
        let root = repoRootFromTests()
        let runner = EvalRunner(repoRoot: root, deterministic: DeterministicEngine())
        let report = try await runner.run()
        let ci = report.cases.filter { $0.status != .skip }
        #expect(!ci.isEmpty)
        #expect(report.cases.contains { $0.id == "no-hardcoded-secrets/hardcoded-api-key" && $0.status == .pass })
        #expect(report.cases.contains { $0.id == "no-hardcoded-secrets/markdown-near-miss" && $0.status == .pass })
        #expect(report.cases.contains { $0.id == "use-project-logger/print-in-production" && $0.status == .skip })
        #expect(report.cases.contains { $0.id == "openapi-breaking-changes/remove-path" && $0.status == .skip })
        #expect(report.failed == 0)
    }
}
