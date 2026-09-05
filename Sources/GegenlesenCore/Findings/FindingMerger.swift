import Foundation

public enum FindingAgreement: String, Sendable, Equatable, Codable {
    case agreed, unique
}

/// One deduplicated defect: a representative finding plus which reviewer
/// slots raised it. `duplicates` are the other slots' copies of the same
/// defect; they are never shown to the judge as separate candidates.
public struct MergedFinding: Sendable, Equatable {
    public var finding: Finding
    public var sources: [ReviewerSlot]
    public var agreement: FindingAgreement
    public var duplicates: [Finding]

    public init(finding: Finding, sources: [ReviewerSlot], agreement: FindingAgreement, duplicates: [Finding] = []) {
        self.finding = finding
        self.sources = sources
        self.agreement = agreement
        self.duplicates = duplicates
    }

    public var sourceNames: String {
        sources.map(\.rawValue).joined(separator: " + ")
    }
}

/// Merges fresh findings from the two reviewer slots before the judge sees
/// them. Two independent models landing on the same line is precision
/// evidence, not noise — cross-slot duplicates previously reached the judge
/// as separate candidates and both survived to the risk gate.
///
/// Key shape follows acpbot's mergePanelReports: same file, overlapping line
/// window, and a normalized title prefix. Findings without a path or line
/// range never merge.
public enum FindingMerger: Sendable {
    public static func mergeAcrossSlots(_ findings: [Finding]) -> [MergedFinding] {
        var groups: [MergedFinding] = []
        for finding in findings {
            if let index = groups.lastIndex(where: { sameDefect($0.finding, finding) }) {
                var group = groups[index]
                group.duplicates.append(finding)
                if !group.sources.contains(finding.reviewerSlot ?? .modelA) {
                    group.sources.append(finding.reviewerSlot ?? .modelA)
                    group.sources.sort { $0.rawValue < $1.rawValue }
                }
                if isBetterRepresentative(finding, than: group.finding) {
                    group.finding = finding
                }
                groups[index] = group
            } else {
                groups.append(
                    MergedFinding(
                        finding: finding,
                        sources: [finding.reviewerSlot ?? .modelA],
                        agreement: .unique
                    )
                )
            }
        }
        return groups.map { group in
            var next = group
            next.agreement = next.sources.count > 1 ? .agreed : .unique
            return next
        }
    }

    /// Duplicate copies of judged defects never reach the ledger as live rows:
    /// they are stamped as drops that name the representative they duplicated.
    public static func stampDuplicates(_ groups: [MergedFinding]) -> [Finding] {
        groups.flatMap { group -> [Finding] in
            guard !group.duplicates.isEmpty else { return [] }
            let representative = group.finding
            return group.duplicates.map { duplicate in
                var dropped = duplicate
                dropped.judgeVerdict = .drop
                dropped.judgeSeverity = duplicate.severity
                dropped.judgeRationale =
                    "host: duplicate of \(representative.id.rawValue) (raised by \(group.sourceNames))"
                return dropped
            }
        }
    }

    static func sameDefect(_ a: Finding, _ b: Finding) -> Bool {
        guard let pathA = a.filePath, let pathB = b.filePath, pathA == pathB else {
            return false
        }
        guard let startA = a.startLine, let endA = a.endLine,
              let startB = b.startLine, let endB = b.endLine else {
            return false
        }
        // Models may anchor the same defect a line or two apart.
        let overlaps = (startA >= startB - 2 && startA <= endB + 2)
            || (startB >= startA - 2 && startB <= endA + 2)
        guard overlaps else { return false }
        return normalizedTitle(a) == normalizedTitle(b)
    }

    static func normalizedTitle(_ finding: Finding) -> String {
        String(Fingerprint.normalizeWhitespace(finding.title).lowercased().prefix(80))
    }

    static func isBetterRepresentative(_ candidate: Finding, than current: Finding) -> Bool {
        let candidateConfidence = candidate.confidence ?? 0
        let currentConfidence = current.confidence ?? 0
        if candidateConfidence != currentConfidence {
            return candidateConfidence > currentConfidence
        }
        if candidate.severity.rank != current.severity.rank {
            return candidate.severity.rank > current.severity.rank
        }
        return candidate.id.rawValue < current.id.rawValue
    }
}
