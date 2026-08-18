import Foundation
import Testing
@testable import MeisterCore

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
