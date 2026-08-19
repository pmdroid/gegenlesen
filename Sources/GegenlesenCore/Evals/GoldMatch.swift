import Foundation

public struct GoldCandidate: Sendable, Equatable {
    public var ruleID: String?
    public var filePath: String?
    public var startLine: Int?
    public var endLine: Int?
    public var severity: Severity

    public init(
        ruleID: String? = nil,
        filePath: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        severity: Severity
    ) {
        self.ruleID = ruleID
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.severity = severity
    }

    public init(_ finding: Finding) {
        self.init(
            ruleID: finding.ruleID?.rawValue,
            filePath: finding.filePath,
            startLine: finding.startLine,
            endLine: finding.endLine,
            severity: finding.severity
        )
    }
}

public enum GoldMatch: Sendable {
    public static func lineRangesOverlap(
        goldStart: Int,
        goldEnd: Int,
        foundStart: Int,
        foundEnd: Int,
        tolerance: Int
    ) -> Bool {
        let goldLo = min(goldStart, goldEnd)
        let goldHi = max(goldStart, goldEnd)
        let foundLo = min(foundStart, foundEnd)
        let foundHi = max(foundStart, foundEnd)
        let expandedLo = goldLo - max(tolerance, 0)
        let expandedHi = goldHi + max(tolerance, 0)
        return expandedLo <= foundHi && foundLo <= expandedHi
    }

    public static func matches(candidate: GoldCandidate, gold: EvalCase) -> Bool {
        guard candidate.ruleID == gold.ruleID else { return false }
        if gold.mustFind {
            guard let expectedPath = gold.filePath, candidate.filePath == expectedPath else { return false }
            guard let foundStart = candidate.startLine, let foundEnd = candidate.endLine,
                  let goldStart = gold.startLine, let goldEnd = gold.endLine
            else { return false }
            guard lineRangesOverlap(
                goldStart: goldStart,
                goldEnd: goldEnd,
                foundStart: foundStart,
                foundEnd: foundEnd,
                tolerance: gold.tolerance
            ) else { return false }
        }
        if let floor = gold.minSeverity, candidate.severity.rank < floor.rank {
            return false
        }
        return true
    }

    public static func hits(candidates: [GoldCandidate], gold: EvalCase) -> [GoldCandidate] {
        candidates.filter { matches(candidate: $0, gold: gold) }
    }

    public static func ruleHits(candidates: [GoldCandidate], ruleID: String) -> [GoldCandidate] {
        candidates.filter { $0.ruleID == ruleID }
    }
}
