import Foundation

/// Harvest/mine used to clone a rule as `…-handwritten` and leave the draft
/// in the list. Accept and promote now flip the same row. Collapse removes
/// the leftover copies.
public enum RulePromotion: Sendable {
    public static func promoteInPlace(_ rule: Rule, at now: Date = Date()) -> Rule {
        var next = rule
        next.provenance = .handwritten
        next.enabled = true
        next.updatedAt = now
        return next
    }

    public static func collapseDuplicates(into store: Store, at now: Date = Date()) async throws -> Int {
        var deleted = 0
        let rules = try await store.listRules(RuleListFilter(includeDeleted: false))
        for rule in rules {
            guard rule.provenance == .handwritten, let source = rule.promotedFromRuleID else { continue }
            if source == rule.id { continue }
            if try await store.softDeleteRule(id: source, at: now) != nil {
                deleted += 1
            }
        }

        let remaining = try await store.listRules(RuleListFilter(includeDeleted: false))
        var groups: [String: [Rule]] = [:]
        for rule in remaining {
            let repo = RepositoryName.normalize(rule.repository) ?? ""
            groups[Normalize.titleKey(rule.title) + "\u{1f}" + repo, default: []].append(rule)
        }
        for group in groups.values where group.count > 1 {
            let keeper = keeper(in: group)
            for rule in group where rule.id != keeper.id {
                if try await store.softDeleteRule(id: rule.id, at: now) != nil {
                    deleted += 1
                }
            }
        }
        return deleted
    }

    static func keeper(in group: [Rule]) -> Rule {
        group.sorted { lhs, rhs in
            let left = score(lhs)
            let right = score(rhs)
            if left != right { return left > right }
            return lhs.id.rawValue.count < rhs.id.rawValue.count
        }[0]
    }

    private static func score(_ rule: Rule) -> Int {
        var value = 0
        if rule.provenance == .handwritten { value += 4 }
        if rule.enabled { value += 2 }
        if !rule.id.rawValue.hasSuffix("-handwritten"), !rule.id.rawValue.hasSuffix("-hw") {
            value += 1
        }
        return value
    }
}
