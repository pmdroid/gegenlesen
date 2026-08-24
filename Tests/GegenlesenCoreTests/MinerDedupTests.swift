import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct MinerDedupTests {
    @Test
    func mineProducesDisabledRules() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let candidate = sampleMinedRule(title: "Ban the widget", refs: ["pr-1"], now: now)
            let outcome = try await MinerDedup.upsert(candidate, into: store, now: now)
            guard case .inserted(let id) = outcome else {
                Issue.record("expected insert")
                return
            }
            let stored = try await store.rule(id: id)
            #expect(stored?.enabled == false)
            #expect(stored?.provenance == .mined)
            #expect(stored?.sourcePRRefs == ["pr-1"])
        }
    }

    @Test
    func sameNormalizedTitleAttachesRefs() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let first = sampleMinedRule(title: "Ban the Widget", refs: ["pr-1"], now: now)
            _ = try await MinerDedup.upsert(first, into: store, now: now)
            let again = sampleMinedRule(title: "  ban   the   widget  ", refs: ["pr-2"], now: now)
            let outcome = try await MinerDedup.upsert(again, into: store, now: now)
            guard case .attached(let id) = outcome else {
                Issue.record("expected attach")
                return
            }
            let rules = try await store.listRules(RuleListFilter(includeDeleted: false))
                .filter { $0.title.lowercased().contains("widget") }
            #expect(rules.count == 1)
            let stored = try await store.rule(id: id)
            #expect(stored?.sourcePRRefs == ["pr-1", "pr-2"])
            #expect(stored?.enabled == false)
        }
    }

    @Test
    func sameGlobsAndFTSTop1AttachesRefs() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let existing = sampleMinedRule(
                id: RuleID("use-project-logger"),
                title: "Use the project logger",
                globs: ["**/*.swift"],
                refs: ["seed"],
                now: now
            )
            try await store.insertRule(existing)
            let candidate = sampleMinedRule(
                title: "project logger",
                globs: ["**/*.swift"],
                refs: ["pr-9"],
                now: now
            )
            let outcome = try await MinerDedup.upsert(candidate, into: store, now: now)
            #expect(outcome == .attached(existing.id))
            let stored = try await store.rule(id: existing.id)
            #expect(stored?.sourcePRRefs == ["seed", "pr-9"])
            let extras = try await store.listRules()
                .filter { $0.id != existing.id && $0.title == candidate.title }
            #expect(extras.isEmpty)
        }
    }

    @Test
    func bodyHitOnDefaultGlobsDoesNotAttach() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let existing = Rule(
                id: RuleID("unrelated-house-note"),
                title: "Unrelated house note",
                severity: .info,
                kind: .semantic,
                enabled: false,
                provenance: .mined,
                languages: [],
                pathGlobs: ["**/*"],
                payload: .semantic(instruction: "Corpus unique widget ban lives in the body", fewShots: []),
                body: "Corpus unique widget ban lives in the body",
                createdAt: now,
                updatedAt: now
            )
            try await store.insertRule(existing)
            let candidate = sampleMinedRule(
                title: "Corpus unique widget ban",
                globs: ["**/*"],
                refs: ["pr-new"],
                now: now
            )
            let outcome = try await MinerDedup.upsert(candidate, into: store, now: now)
            guard case .inserted = outcome else {
                Issue.record("expected insert, got \(outcome)")
                return
            }
            let stored = try await store.rule(id: existing.id)
            #expect(stored?.sourcePRRefs.isEmpty == true)
        }
    }

    @Test
    func globSetEqualityIgnoresOrder() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let existing = sampleMinedRule(
                id: RuleID("swift-logger-style"),
                title: "Use the project logger",
                globs: ["**/*.swift", "!**/*Tests.swift"],
                refs: ["seed"],
                now: now
            )
            try await store.insertRule(existing)
            let candidate = sampleMinedRule(
                title: "project logger",
                globs: ["!**/*Tests.swift", "**/*.swift"],
                refs: ["pr-9"],
                now: now
            )
            let outcome = try await MinerDedup.upsert(candidate, into: store, now: now)
            #expect(outcome == .attached(existing.id))
        }
    }
}

@Suite
struct LearningDedupTests {
    @Test
    func settledTitleBlocksRepeat() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await store.insertLearning(
                Learning(
                    kind: .rule,
                    status: .dismissed,
                    title: "Use the project logger",
                    body: "old",
                    payloadJSON: #"{"rule_id":"harvest-use-the-project-logger"}"#,
                    resolvedAt: Date()
                )
            )
            #expect(
                try await LearningDedup.alreadySettled(
                    store: store,
                    kind: .rule,
                    title: "use the  project logger",
                    ruleID: "other"
                )
            )
            #expect(
                try await LearningDedup.alreadySettled(
                    store: store,
                    kind: .rule,
                    title: "A different rule",
                    ruleID: "harvest-use-the-project-logger"
                )
            )
            #expect(
                try await LearningDedup.alreadySettled(
                    store: store,
                    kind: .rule,
                    title: "Brand new"
                ) == false
            )
        }
    }

    @Test
    func pendingTitleBlocksRepeatAndRestoreClearsDismissedHash() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            var item = Learning(
                kind: .context,
                status: .pending,
                title: "Notes from job-1",
                body: "one"
            )
            try await store.insertLearning(item)
            #expect(
                try await LearningDedup.alreadySettled(
                    store: store,
                    kind: .context,
                    title: "notes from  job-1"
                )
            )
            item.status = .dismissed
            item.resolvedAt = Date()
            item.applyDismiss(reason: .tooSpecific, comment: "n=1")
            try await store.updateLearning(item)
            #expect(
                try await LearningDedup.alreadySettled(
                    store: store,
                    kind: .context,
                    title: "Notes from job-1"
                )
            )
            item.clearDismiss()
            item.status = .pending
            item.resolvedAt = nil
            try await store.updateLearning(item)
            #expect(item.dismissReason == nil)
            #expect(
                try await LearningDedup.alreadySettled(
                    store: store,
                    kind: .context,
                    title: "Notes from job-1"
                )
            )
            let rows = LearningDedup.yield(from: [
                Learning(kind: .rule, status: .accepted, title: "a", body: "a"),
                Learning(kind: .rule, status: .dismissed, title: "b", body: "b"),
                Learning(kind: .rule, status: .pending, title: "c", body: "c"),
                Learning(kind: .context, status: .accepted, title: "d", body: "d"),
            ])
            let rule = try #require(rows.first { $0.kind == .rule })
            #expect(rule.accepted == 1)
            #expect(rule.dismissed == 1)
            #expect(rule.rate == 0.5)
            let context = try #require(rows.first { $0.kind == .context })
            #expect(context.accepted == 1)
            #expect(context.dismissed == 0)
            #expect(context.rate == 1)
            let architecture = try #require(rows.first { $0.kind == .architecture })
            #expect(architecture.accepted == 0)
            #expect(architecture.rate == 0)
        }
    }

    @Test
    func acceptedContextNoteBlocksRepeat() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await store.insertContextNote(
                ContextNote(title: "OpenCode Server Control Plane", body: "durable")
            )
            #expect(
                try await LearningDedup.alreadySettled(
                    store: store,
                    kind: .context,
                    title: "opencode server control plane"
                )
            )
        }
    }
}

private func sampleMinedRule(
    id: RuleID? = nil,
    title: String,
    globs: [String] = ["**/*"],
    refs: [String],
    now: Date
) -> Rule {
    Rule(
        id: id ?? RuleID.slug(from: title),
        title: title,
        severity: .warning,
        kind: .semantic,
        enabled: true,
        provenance: .mined,
        languages: ["swift"],
        pathGlobs: globs,
        payload: .semantic(instruction: title, fewShots: []),
        sourcePRRefs: refs,
        createdAt: now,
        updatedAt: now
    )
}
