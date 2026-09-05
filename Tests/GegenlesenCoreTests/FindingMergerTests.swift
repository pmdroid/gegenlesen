import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct FindingMergerTests {
    private func finding(
        slot: ReviewerSlot,
        title: String = "Cache describe runs with disabled cache",
        path: String = "apps/condex/internal/store/postgres/store.go",
        start: Int = 90,
        end: Int = 90,
        confidence: Double? = nil,
        severity: Severity = .warning
    ) -> Finding {
        Finding(
            id: FindingID.generate(),
            jobID: JobID.generate(),
            phase: .agent,
            reviewerSlot: slot,
            severity: severity,
            title: title,
            message: "The describe call silently tolerates a disabled cache.",
            filePath: path,
            startLine: start,
            endLine: end,
            snippet: "res := cache.Describe(ctx)",
            confidence: confidence,
            createdAt: Date()
        )
    }

    @Test
    func twoSlotsSameDefectMergeToAgreed() {
        let a = finding(slot: .modelA, confidence: 0.8)
        let b = finding(slot: .modelB, confidence: 0.6)
        let merged = FindingMerger.mergeAcrossSlots([a, b])
        #expect(merged.count == 1)
        #expect(merged[0].agreement == .agreed)
        #expect(merged[0].sources == [.modelA, .modelB])
        #expect(merged[0].duplicates.count == 1)
        #expect(merged[0].finding.id == a.id)
    }

    @Test
    func differentDefectsStayUntouched() {
        let a = finding(slot: .modelA, title: "Cache describe runs with disabled cache")
        let b = finding(
            slot: .modelB,
            title: "Connect test leaks prepared statement",
            path: "apps/condex/internal/store/postgres/connect_test.go",
            start: 73
        )
        let merged = FindingMerger.mergeAcrossSlots([a, b])
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.agreement == .unique && $0.duplicates.isEmpty })
    }

    @Test
    func lineWindowToleratesOffByTwoButNotFarLines() {
        let a = finding(slot: .modelA, start: 90, end: 94)
        let b = finding(slot: .modelB, start: 92, end: 96)
        let far = finding(slot: .modelB, start: 140, end: 140)
        let merged = FindingMerger.mergeAcrossSlots([a, b, far])
        #expect(merged.count == 2)
        #expect(merged[0].agreement == .agreed)
        #expect(merged[1].agreement == .unique)
    }

    @Test
    func representativePrefersHigherConfidenceThenSeverity() {
        let lowConfidence = finding(slot: .modelA, confidence: 0.3, severity: .info)
        let strong = finding(slot: .modelB, confidence: 0.9, severity: .error)
        let merged = FindingMerger.mergeAcrossSlots([lowConfidence, strong])
        #expect(merged[0].finding.id == strong.id)
    }

    @Test
    func findingsWithoutPathOrLineNeverMerge() {
        let a = finding(slot: .modelA)
        var noPath = finding(slot: .modelB)
        noPath.filePath = nil
        var noLine = finding(slot: .modelB)
        noLine.startLine = nil
        #expect(FindingMerger.mergeAcrossSlots([a, noPath]).count == 2)
        #expect(FindingMerger.mergeAcrossSlots([a, noLine]).count == 2)
    }

    @Test
    func stampDuplicatesMarksDropsNamingRepresentative() throws {
        let a = finding(slot: .modelA, confidence: 0.8)
        let b = finding(slot: .modelB)
        let groups = FindingMerger.mergeAcrossSlots([a, b])
        let drops = FindingMerger.stampDuplicates(groups)
        #expect(drops.count == 1)
        let dropped = try #require(drops.first)
        #expect(dropped.id == b.id)
        #expect(dropped.judgeVerdict == .drop)
        #expect(dropped.judgeRationale?.contains("duplicate of \(a.id.rawValue)") == true)
        #expect(dropped.judgeRationale?.contains("model_a + model_b") == true)
    }
}
