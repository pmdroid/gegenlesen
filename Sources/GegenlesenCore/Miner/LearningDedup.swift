import Foundation

public struct LearningYield: Sendable, Equatable {
    public var kind: LearningKind
    public var accepted: Int
    public var dismissed: Int

    public init(kind: LearningKind, accepted: Int, dismissed: Int) {
        self.kind = kind
        self.accepted = accepted
        self.dismissed = dismissed
    }

    public var rate: Double {
        let total = accepted + dismissed
        guard total > 0 else { return 0 }
        return Double(accepted) / Double(total)
    }
}

/// Inbox items the operator already accepted or dismissed must not come back
/// on the next harvest or learn pass. Title match is `Normalize.titleKey`.
/// Restoring a dismiss (status back to pending) puts the same card in the
/// inbox again; a new row is not inserted while that title still exists.
public enum LearningDedup: Sendable {
    public static func alreadySettled(
        store: Store,
        kind: LearningKind,
        title: String,
        ruleID: String? = nil
    ) async throws -> Bool {
        let key = Normalize.titleKey(title)
        let items = try await store.listLearnings(status: nil, kind: kind)
        for item in items {
            if Normalize.titleKey(item.title) == key {
                return true
            }
            if let ruleID, payloadString(item.payloadJSON, key: "rule_id") == ruleID {
                return true
            }
        }
        if kind == .context {
            let notes = try await store.listContextNotes()
            if notes.contains(where: { Normalize.titleKey($0.title) == key }) {
                return true
            }
        }
        if kind == .rule {
            let rules = try await store.listRules(RuleListFilter(includeDeleted: false))
            if rules.contains(where: {
                $0.enabled
                    && $0.provenance == .handwritten
                    && Normalize.titleKey($0.title) == key
            }) {
                return true
            }
        }
        return false
    }

    public static func dismissedArchitecture(store: Store, bodyHash: String) async throws -> Bool {
        let items = try await store.listLearnings(status: .dismissed, kind: .architecture)
        return items.contains { ContentHash.sha256(Data($0.body.utf8)) == bodyHash }
    }

    public static func yield(from items: [Learning]) -> [LearningYield] {
        LearningKind.allCases.map { kind in
            let slice = items.filter { $0.kind == kind }
            return LearningYield(
                kind: kind,
                accepted: slice.filter { $0.status == .accepted }.count,
                dismissed: slice.filter { $0.status == .dismissed }.count
            )
        }
    }

    private static func payloadString(_ raw: String?, key: String) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }
}
