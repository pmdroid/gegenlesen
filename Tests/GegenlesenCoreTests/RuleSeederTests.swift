import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct RuleSeederTests {
    @Test
    func upsertDoesNotOverwrite() async throws {
        try await withTempDataDir { dir in
            let seeds = dir.appendingPathComponent("seeds", isDirectory: true)
            try FileManager.default.createDirectory(at: seeds, withIntermediateDirectories: true)
            let yaml = """
            id: no-hardcoded-secrets
            title: Seed title
            severity: error
            enabled: true
            kind: deterministic
            provenance: handwritten
            languages: ["*"]
            path_globs:
              - "**/*"
            payload:
              checker: regex
              pattern: "secret"
              message: "seed"
            body: seed-body
            """
            try yaml.write(
                to: seeds.appendingPathComponent("no-hardcoded-secrets.yaml"),
                atomically: true,
                encoding: .utf8
            )
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let existing = Rule(
                id: RuleID("no-hardcoded-secrets"),
                title: "Operator title",
                severity: .warning,
                kind: .deterministic,
                languages: ["*"],
                pathGlobs: ["**/*"],
                payload: .regex(pattern: "token", flags: nil, message: "operator"),
                body: "operator-body",
                createdAt: now,
                updatedAt: now
            )
            try await store.insertRule(existing)
            let inserted = try await RuleSeeder.upsertAbsent(from: seeds, into: store)
            #expect(inserted == 0)
            let loaded = try await store.rule(id: RuleID("no-hardcoded-secrets"))
            #expect(loaded?.title == "Operator title")
            #expect(loaded?.body == "operator-body")
        }
    }

    @Test
    func upsertInsertsMissingSeed() async throws {
        try await withTempDataDir { dir in
            let seeds = dir.appendingPathComponent("seeds", isDirectory: true)
            try FileManager.default.createDirectory(at: seeds, withIntermediateDirectories: true)
            try """
            id: use-project-logger
            title: Use the project logger
            severity: warning
            kind: semantic
            languages: ["swift"]
            path_globs:
              - "**/*.swift"
            payload:
              instruction: Prefer Logger
            body: house style
            """.write(
                to: seeds.appendingPathComponent("use-project-logger.yaml"),
                atomically: true,
                encoding: .utf8
            )
            let store = try Store.open(dataDir: dir)
            let inserted = try await RuleSeeder.upsertAbsent(from: seeds, into: store)
            #expect(inserted == 1)
            let loaded = try await store.rule(id: RuleID("use-project-logger"))
            #expect(loaded?.title == "Use the project logger")
            if case .semantic(let instruction, _) = loaded?.payload {
                #expect(instruction.contains("Logger"))
            } else {
                Issue.record("expected semantic payload")
            }
        }
    }
}