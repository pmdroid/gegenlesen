import Foundation
import Testing
@testable import MeisterCore

@Suite
struct RuleSelectorTests {
    @Test
    func enabledGlobAndLanguage() {
        let rule = sampleRule(
            enabled: true,
            languages: ["swift"],
            globs: ["**/*.swift", "!**/*Tests.swift"]
        )
        let files = [
            jobFile("Sources/A.swift", .swift),
            jobFile("Sources/ATests.swift", .swift),
            jobFile("web/app.ts", .typescript),
            jobFile("node_modules/x.swift", .swift),
        ]
        let selected = RuleSelector().select(rules: [rule], files: files)
        #expect(selected.count == 1)
        #expect(selected[0].files.map(\.path) == ["Sources/A.swift"])
    }

    @Test
    func starLanguageMatchesOther() {
        let rule = sampleRule(languages: ["*"], globs: ["**/*"])
        let files = [jobFile("Makefile", .other)]
        let selected = RuleSelector().select(rules: [rule], files: files)
        #expect(selected.first?.files.count == 1)
    }

    @Test
    func ranksSemanticByGlobLanguageHandwrittenAndFTS() {
        let catchAll = sampleRule(
            id: "catch-all",
            languages: ["*"],
            globs: ["**/*"],
            payload: .semantic(instruction: "generic", fewShots: [])
        )
        var mined = catchAll
        mined.id = RuleID("mined-generic")
        mined.provenance = .mined
        mined.title = "Mined generic"
        var specific = sampleRule(
            id: "swift-logger",
            languages: ["swift"],
            globs: ["Sources/**/*.swift"],
            payload: .semantic(instruction: "use the project logger", fewShots: [])
        )
        specific.provenance = .handwritten
        specific.title = "Use project logger"
        let files = [jobFile("Sources/A.swift", .swift)]
        let selected = RuleSelector().select(
            rules: [mined, specific],
            files: files,
            ftsScores: [specific.id: 4, mined.id: 0.1]
        )
        #expect(selected.map { $0.rule.id.rawValue } == ["swift-logger", "mined-generic"])
        #expect(selected[0].score > selected[1].score)
        #expect(selected[0].score == 3 + 2 + 4 + 1)
    }

    @Test
    func deterministicAlwaysSelectedWithoutScoreBudget() {
        let det = sampleRule(id: "regex-secret", globs: ["**/*"])
        var sem = sampleRule(
            id: "semantic-house",
            languages: ["swift"],
            globs: ["**/*.swift"],
            payload: .semantic(instruction: "house", fewShots: [])
        )
        sem.provenance = .mined
        let files = [jobFile("Sources/A.swift", .swift)]
        let selected = RuleSelector().select(rules: [sem, det], files: files)
        #expect(selected.first?.rule.id.rawValue == "regex-secret")
        #expect(selected.first?.score == 0)
        #expect(selected.contains { $0.rule.id.rawValue == "semantic-house" })
    }

    @Test
    func disabledAndDeletedAreSkipped() {
        let disabled = sampleRule(id: "off", enabled: false)
        var deleted = sampleRule(id: "gone")
        deleted.deletedAt = Date()
        let files = [jobFile("Sources/A.swift", .swift)]
        #expect(RuleSelector().select(rules: [disabled, deleted], files: files).isEmpty)
    }
}

func sampleRule(
    id: String = "sample-rule",
    enabled: Bool = true,
    languages: [String] = ["*"],
    globs: [String] = ["**/*"],
    payload: RulePayload = .regex(pattern: "secret", flags: nil, message: "hit")
) -> Rule {
    let now = Date()
    return Rule(
        id: RuleID(id),
        title: "Sample",
        severity: .error,
        kind: payload.isSemantic ? .semantic : .deterministic,
        enabled: enabled,
        languages: languages,
        pathGlobs: globs,
        payload: payload,
        createdAt: now,
        updatedAt: now
    )
}

func jobFile(_ path: String, _ language: Language, status: FileChangeStatus = .modified) -> JobFile {
    JobFile(jobID: JobID("job"), path: path, status: status, language: language)
}