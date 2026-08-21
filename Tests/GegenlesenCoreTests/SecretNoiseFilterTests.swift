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
        #expect(SecretNoiseFilter.isPlaceholder("openrouter_api_key"))
        #expect(SecretNoiseFilter.isPlaceholder("qwertyuiopasdfgh"))
        #expect(!SecretNoiseFilter.isPlaceholder("Kj8dN2pQw9LmX4vB7cR1tY"))
        #expect(!SecretNoiseFilter.isPlaceholder("sk-live-9f3a1c82b4d7e6"))
    }

    @Test
    func dropsPlantedPathsForScannerSecretsOnly() {
        let match = "api_key = \"Kj8dN2pQw9LmX4vB7cR1tY\""
        #expect(
            SecretNoiseFilter.shouldDrop(
                ruleID: RuleID("scanner-gitleaks"),
                filePath: "evals/cases/secrets/head/Sources/Config.swift",
                match: match
            )
        )
        #expect(
            !SecretNoiseFilter.shouldDrop(
                ruleID: RuleID("scanner-gitleaks"),
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
        #expect(SecretNoiseFilter.plantedGlobs.matches("App/fixtures/keys.swift"))
        #expect(!SecretNoiseFilter.plantedGlobs.matches("Sources/GegenlesenCore/Evals/EvalPacker.swift"))
    }
}
