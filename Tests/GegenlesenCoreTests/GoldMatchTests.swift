import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct GoldMatchTests {
    @Test
    func overlapWithinTolerance() {
        #expect(GoldMatch.lineRangesOverlap(goldStart: 10, goldEnd: 12, foundStart: 11, foundEnd: 11, tolerance: 0))
        #expect(GoldMatch.lineRangesOverlap(goldStart: 10, goldEnd: 10, foundStart: 12, foundEnd: 12, tolerance: 2))
        #expect(!GoldMatch.lineRangesOverlap(goldStart: 10, goldEnd: 10, foundStart: 14, foundEnd: 14, tolerance: 2))
    }

    @Test
    func matchRequiresRulePathLinesAndSeverityFloor() {
        let gold = EvalCase(
            id: "hit",
            directory: URL(fileURLWithPath: "/tmp/hit"),
            ruleID: "no-hardcoded-secrets",
            layer: .rules,
            mustFind: true,
            filePath: "Sources/Config.swift",
            startLine: 3,
            endLine: 3,
            tolerance: 2,
            minSeverity: .error,
            ci: true,
            hasTwin: false
        )
        let hit = GoldCandidate(
            ruleID: "no-hardcoded-secrets",
            filePath: "Sources/Config.swift",
            startLine: 4,
            endLine: 4,
            severity: .error
        )
        #expect(GoldMatch.matches(candidate: hit, gold: gold))

        let wrongPath = GoldCandidate(
            ruleID: "no-hardcoded-secrets",
            filePath: "Sources/Other.swift",
            startLine: 3,
            endLine: 3,
            severity: .error
        )
        #expect(!GoldMatch.matches(candidate: wrongPath, gold: gold))

        let warning = GoldCandidate(
            ruleID: "no-hardcoded-secrets",
            filePath: "Sources/Config.swift",
            startLine: 3,
            endLine: 3,
            severity: .warning
        )
        #expect(!GoldMatch.matches(candidate: warning, gold: gold))
    }

    @Test
    func loadCorpusFromRepo() throws {
        let root = repoRootFromTests()
        let cases = try EvalCorpus.load(casesRoot: root.appendingPathComponent("evals/cases"))
        let ids = Set(cases.map(\.id))
        #expect(ids.contains("no-hardcoded-secrets/hardcoded-api-key"))
        #expect(ids.contains("no-hardcoded-secrets/markdown-near-miss"))
        #expect(ids.contains("openapi-breaking-changes/remove-path"))
        #expect(ids.contains("use-project-logger/print-in-production"))
        let secrets = try #require(cases.first { $0.id == "no-hardcoded-secrets/hardcoded-api-key" })
        #expect(secrets.hasTwin)
        #expect(secrets.ci)
        let logger = try #require(cases.first { $0.id == "use-project-logger/print-in-production" })
        #expect(logger.layer == .agent)
        #expect(!logger.ci)
    }
}
