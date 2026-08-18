import Foundation
import Testing
@testable import MeisterCore

@Suite
struct PromptBudgetTests {
    @Test
    func tokensAreCharsOverFour() {
        #expect(PromptBudget.tokens("abcd") == 1)
        #expect(PromptBudget.tokens("abcdefgh") == 2)
        #expect(PromptBudget.tokens("") == 0)
    }

    @Test
    func truncatesFewShotsBeforeDroppingMined() {
        var handwritten = sampleRule(
            id: "hw-title",
            payload: .semantic(
                instruction: String(repeating: "H", count: 40),
                fewShots: [String(repeating: "S", count: 80)]
            )
        )
        handwritten.provenance = .handwritten
        handwritten.title = "Handwritten title"
        var mined = sampleRule(
            id: "mined-long",
            payload: .semantic(
                instruction: String(repeating: "M", count: 80),
                fewShots: [String(repeating: "F", count: 80)]
            )
        )
        mined.provenance = .mined
        mined.title = "Mined filler"

        let budget = PromptBudget(tokenBudget: PromptBudget.tokens("Handwritten title\n" + String(repeating: "H", count: 40)) + 2)
        let applied = budget.apply([handwritten, mined])
        #expect(applied.contains { $0.id.rawValue == "hw-title" })
        #expect(applied.contains { $0.id.rawValue == "hw-title" && $0.title == "Handwritten title" })
        if let hw = applied.first(where: { $0.id.rawValue == "hw-title" }),
           case .semantic(_, let few) = hw.payload {
            #expect(few.isEmpty)
        } else {
            Issue.record("handwritten rule missing")
        }
        #expect(!applied.contains { $0.id.rawValue == "mined-long" })
    }

    @Test
    func keepsHandwrittenTitleWhenStillOverBudget() {
        var handwritten = sampleRule(
            id: "keep-title",
            payload: .semantic(instruction: String(repeating: "X", count: 400), fewShots: [])
        )
        handwritten.provenance = .handwritten
        handwritten.title = "Must keep this title"
        let applied = PromptBudget(tokenBudget: 1).apply([handwritten])
        #expect(applied.count == 1)
        #expect(applied[0].title == "Must keep this title")
    }
}
