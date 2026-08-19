import Foundation
import Testing
@testable import GegenlesenAgent

@Suite
struct SecretRedactorTests {
    @Test
    func sampleTranscriptHasNoRemainingSecrets() throws {
        let url = repoRootFromAgentTests()
            .appendingPathComponent("Tests/Fixtures/transcripts/sample-run.ndjson")
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains("sk-"))
        #expect(raw.contains("ANTHROPIC_API_KEY"))
        let redacted = SecretRedactor().redact(raw)
        #expect(!redacted.contains("sk-"))
        #expect(!redacted.contains("sk-ant-api03-SUPERSECRETVALUE0001"))
        #expect(!redacted.contains("sk-live-abcdefghijklmnopqrstuvwxyz012345"))
        #expect(!redacted.contains("sk-proj-openai-secret-aaaa"))
        #expect(!redacted.contains("sk-or-v1-openrouter-secret-bbbb"))
        #expect(!redacted.contains("SUPERSECRETVALUE0001"))
        #expect(redacted.contains("ANTHROPIC_API_KEY=[REDACTED]"))
    }
}
