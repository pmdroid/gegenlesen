import Foundation
import Testing
@testable import GegenlesenCore
@testable import GegenlesenDeterministic

@Suite
struct SecretNoiseFilterTests {
    @Test
    func dropsAlphabetAndPlaceholderLiterals() {
        #expect(SecretNoiseFilter.isPlaceholder("abcdefghijklmnopqrstuvwxyz"))
        #expect(SecretNoiseFilter.isPlaceholder("xxxxxxxxxxxxxxxx"))
        #expect(SecretNoiseFilter.isPlaceholder("changemechangeme"))
        #expect(SecretNoiseFilter.isPlaceholder("your-api-key-here-ok"))
        #expect(SecretNoiseFilter.isPlaceholder("qwertyuiopasdfgh"))
        #expect(!SecretNoiseFilter.isPlaceholder("Kj8dN2pQw9LmX4vB7cR1tY"))
        #expect(!SecretNoiseFilter.isPlaceholder("sk-live-9f3a1c82b4d7e6"))
    }

    @Test
    func dropsPlantedEvalPathsOnlyForSecretsRule() {
        let match = "api_key = \"Kj8dN2pQw9LmX4vB7cR1tY\""
        #expect(
            SecretNoiseFilter.shouldDrop(
                ruleID: RuleID("no-hardcoded-secrets"),
                filePath: "evals/cases/no-hardcoded-secrets/hardcoded-api-key/head/Sources/Config.swift",
                match: match
            )
        )
        #expect(
            !SecretNoiseFilter.shouldDrop(
                ruleID: RuleID("no-hardcoded-secrets"),
                filePath: "Sources/Config.swift",
                match: match
            )
        )
        #expect(
            !SecretNoiseFilter.shouldDrop(
                ruleID: RuleID("other-rule"),
                filePath: "evals/cases/x/Config.swift",
                match: match
            )
        )
    }

    @Test
    func regexCheckerSkipsFakeSecretKeepsReal() async throws {
        try await withTempDir("secret-noise") { root in
            try writeFile(
                "Sources/App.swift",
                "let api_key = \"abcdefghijklmnopqrstuvwxyz\"\nlet token = \"Kj8dN2pQw9LmX4vB7cR1tY\"\n",
                in: root
            )
            try writeFile(
                "evals/cases/no-hardcoded-secrets/head/Sources/Config.swift",
                "let api_key = \"Kj8dN2pQw9LmX4vB7cR1tY\"\n",
                in: root
            )
            let job = JobID("job")
            let files = [
                JobFile(jobID: job, path: "Sources/App.swift", status: .modified, language: .swift),
                JobFile(
                    jobID: job,
                    path: "evals/cases/no-hardcoded-secrets/head/Sources/Config.swift",
                    status: .added,
                    language: .swift
                ),
            ]
            let rule = sampleRule(
                id: "no-hardcoded-secrets",
                globs: ["**/*"],
                payload: .regex(
                    pattern: #"(?i)(api[_-]?key|secret|token)\s*[:=]\s*['"][A-Za-z0-9_\-]{16,}"#,
                    flags: nil,
                    message: "Possible hardcoded secret."
                )
            )
            let result = await DeterministicEngine().run(
                files: files,
                workspace: Workspace(root: root),
                rules: [rule],
                timeout: .seconds(5)
            )
            #expect(!result.timedOut)
            #expect(result.drafts.count == 1)
            #expect(result.drafts[0].filePath == "Sources/App.swift")
            #expect(result.drafts[0].snippet.contains("Kj8dN2pQw9LmX4vB7cR1tY"))
        }
    }
}
