import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct SuggestionFilterTests {
    @Test
    func jobRuleNeedsEndorse() {
        let finding = sampleFinding(title: "Silent hop errors", verdict: .keep)
        let draft = MinedRuleDraft(
            title: "Silent hop errors",
            payload: .semantic(instruction: "log hop failures", fewShots: []),
            body: "log hop failures"
        )
        #expect(
            SuggestionFilter.keepJobRule(draft: draft, findings: [finding], feedback: []) == false
        )
        let up = FindingFeedback(
            id: 1,
            findingID: finding.id,
            jobID: finding.jobID,
            ts: Date(),
            verdict: .agree,
            reaction: .thumbsUp
        )
        #expect(
            SuggestionFilter.keepJobRule(draft: draft, findings: [finding], feedback: [up]) == true
        )
    }

    @Test
    func droppedFindingNeverBecomesARule() {
        let finding = sampleFinding(title: "flaky test note", verdict: .drop)
        let draft = MinedRuleDraft(
            title: "flaky test note",
            payload: .semantic(instruction: "x", fewShots: []),
            body: "x"
        )
        let up = FindingFeedback(
            id: 1,
            findingID: finding.id,
            jobID: finding.jobID,
            ts: Date(),
            verdict: .agree,
            reaction: .thumbsUp
        )
        #expect(
            SuggestionFilter.keepJobRule(draft: draft, findings: [finding], feedback: [up]) == false
        )
    }

    @Test
    func contextOmitsUnendorsedDump() {
        let finding = sampleFinding(title: "one", verdict: .keep)
        #expect(SuggestionFilter.contextBody(findings: [finding], feedback: []) == nil)
        let up = FindingFeedback(
            id: 1,
            findingID: finding.id,
            jobID: finding.jobID,
            ts: Date(),
            verdict: .shouldBeRule
        )
        let body = SuggestionFilter.contextBody(findings: [finding], feedback: [up])
        #expect(body?.contains("one") == true)
    }

    @Test
    func suggestionJudgeDefaultsToDropAndAppliesRewrite() {
        let candidates = [
            SuggestionCandidate(id: "sug_rule_0", kind: .rule, title: "t", body: "b"),
            SuggestionCandidate(id: "sug_context", kind: .context, title: "n", body: "n"),
        ]
        let payload = """
        {"verdicts":[
          {"finding_id":"sug_rule_0","verdict":"keep","rationale":"reusable",
           "rewrite":{"title":"Log hop failures","body":"Log far-end open errors with a credential-free target."}},
          {"finding_id":"sug_context","verdict":"drop","rationale":"recap"}
        ]}
        """
        let kept = SuggestionJudge.apply(
            outcome: SuggestionJudge.parse(Data(payload.utf8)),
            candidates: candidates,
            fallbackIDs: Set(candidates.map(\.id))
        )
        #expect(kept.count == 1)
        #expect(kept[0].id == "sug_rule_0")
        #expect(kept[0].title == "Log hop failures")
        #expect(kept[0].body.contains("credential-free"))
    }
}

private func sampleFinding(title: String, verdict: JudgeVerdict) -> Finding {
    Finding(
        id: FindingID.generate(),
        jobID: JobID("job-1"),
        phase: .agent,
        severity: .warning,
        title: title,
        message: "m",
        filePath: "Sources/A.swift",
        startLine: 1,
        endLine: 1,
        snippet: "x",
        judgeVerdict: verdict,
        evidenceOK: true,
        createdAt: Date()
    )
}
