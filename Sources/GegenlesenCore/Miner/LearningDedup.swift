import Foundation

/// Inbox items the operator already accepted or dismissed must not come back
/// on the next harvest or learn pass.
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
            guard item.status == .accepted || item.status == .dismissed else { continue }
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

    private static func payloadString(_ raw: String?, key: String) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[key] as? String
    }
}
