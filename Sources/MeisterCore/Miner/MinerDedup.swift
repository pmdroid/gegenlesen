import Foundation

public enum MinerDedup: Sendable {
    public enum Outcome: Equatable, Sendable {
        case inserted(RuleID)
        case attached(RuleID)
    }

    public static func upsert(
        _ candidate: Rule,
        into store: Store,
        now: Date = Date()
    ) async throws -> Outcome {
        var rule = candidate
        rule.enabled = false
        rule.updatedAt = now
        if rule.createdAt.timeIntervalSince1970 == 0 {
            rule.createdAt = now
        }

        let key = Normalize.titleKey(rule.title)
        let existing = try await store.listRules(RuleListFilter(includeDeleted: false))
        if let match = existing.first(where: { Normalize.titleKey($0.title) == key }) {
            _ = try await store.appendSourcePRRefs(id: match.id, refs: rule.sourcePRRefs, at: now)
            return .attached(match.id)
        }

        if let top = try await store.ftsTop1Rule(matching: rule.title),
           PatchGlobs.equivalent(top.pathGlobs, rule.pathGlobs) {
            _ = try await store.appendSourcePRRefs(id: top.id, refs: rule.sourcePRRefs, at: now)
            return .attached(top.id)
        }

        rule.id = try await uniqueID(base: rule.id, store: store)
        try await store.insertRule(rule)
        return .inserted(rule.id)
    }

    private static func uniqueID(base: RuleID, store: Store) async throws -> RuleID {
        let root = base.isValid ? base : (RuleID.slug(from: base.rawValue).isValid ? RuleID.slug(from: base.rawValue) : RuleID("mined-rule"))
        var candidate = root
        var suffix = 2
        while try await store.rule(id: candidate) != nil {
            let raw = String(root.rawValue.prefix(120)) + "-\(suffix)"
            candidate = RuleID(raw)
            suffix += 1
            if suffix > 10_000 {
                candidate = RuleID("mined-\(UUID().uuidString.lowercased().prefix(8))")
                break
            }
        }
        return candidate
    }
}
