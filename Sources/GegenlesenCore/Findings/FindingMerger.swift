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
        var groups: [(members: [Finding], sources: [ReviewerSlot])] = []
        for finding in findings {
            if let index = groups.lastIndex(where: { group in
                group.members.contains { sameDefect($0, finding) }
            }) {
                groups[index].members.append(finding)
                if let slot = finding.reviewerSlot, !groups[index].sources.contains(slot) {
                    groups[index].sources.append(slot)
                    groups[index].sources.sort { $0.rawValue < $1.rawValue }
                }
            } else if let slot = finding.reviewerSlot {
                groups.append((members: [finding], sources: [slot]))
            } else {
                groups.append((members: [finding], sources: []))
            }
        }
        return groups.map { group in
            // Pick the representative after grouping so it is never part of
            // its own duplicates, regardless of input order.
            let representative = group.members.reduce(group.members[0]) {
                isBetterRepresentative($1, than: $0) ? $1 : $0
            }
            let duplicates = group.members.filter { $0.id != representative.id }
            let sources = group.members.compactMap(\.reviewerSlot)
            let distinct = Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
            return MergedFinding(
                finding: representative,
                sources: distinct,
                agreement: distinct.count > 1 ? .agreed : .unique,
                duplicates: duplicates
            )
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
