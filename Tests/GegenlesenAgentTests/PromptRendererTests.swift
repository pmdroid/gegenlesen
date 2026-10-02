import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct PromptRendererTests {
    @Test
    func reviewPromptRequiresEvidenceAndSavesConfirmedFindings() {
        let prompt = PromptRenderer().prompt(
            job: sampleJob(),
            fileCount: 4,
            slot: .modelA
        )
        #expect(prompt.contains("Complete these steps for each finding before writing it"))
        #expect(prompt.contains("Save confirmed findings as you go"))
        #expect(prompt.contains(".gegenlesen/findings-model_a.json"))
        #expect(prompt.contains("You may use bash, LSP, grep, tests, and fetch"))
        #expect(!prompt.contains("Do not use bash except"))
        #expect(prompt.contains("Read changed hunks and their enclosing function or type"))
        #expect(prompt.contains("You MUST Write that file before you stop"))
        #expect(prompt.contains("Never write \"Called the Read tool\""))
        #expect(prompt.contains("Do not report placeholder credentials"))
    }

    @Test
    func judgePromptRequiresReadingCitedSource() throws {
        try withTempDir("judge-prompt") { root in
            try PromptRenderer().write(
                workspace: Workspace(root: root),
                job: sampleJob(),
                files: [],
                rules: []
            )
            let text = try String(
                contentsOf: root.appendingPathComponent(".gegenlesen/prompt-judge.md"),
                encoding: .utf8
            )
            #expect(text.contains("Do not decide from the finding title"))
            #expect(text.contains("Read file_path around start_line"))
            #expect(text.contains("KEEP only if you confirmed the claim in source"))
            #expect(!text.contains("Default is KEEP"))
        }
    }
}
