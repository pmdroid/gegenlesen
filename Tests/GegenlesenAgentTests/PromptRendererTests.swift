import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct PromptRendererTests {
    @Test
    func reviewPromptForbidsWritingBeforeInvestigation() {
        let prompt = PromptRenderer().prompt(
            job: sampleJob(),
            fileCount: 4,
            slot: .modelA
        )
        #expect(prompt.contains("Do not Write findings until steps 1–4"))
        #expect(prompt.contains(".gegenlesen/findings-model_a.json"))
        #expect(prompt.contains("You may use bash, LSP, grep, tests, and fetch"))
        #expect(!prompt.contains("Do not use bash except"))
        #expect(prompt.contains("Open every source/config/test path in files.json"))
        #expect(prompt.contains("You MUST Write that file before you stop"))
        #expect(prompt.contains("Never write \"Called the Read tool\""))
    }
}
