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
    func endorsedDroppedFindingIsLearnEligible() {
        let finding = sampleFinding(title: "flaky test note", verdict: .drop)
        let draft = MinedRuleDraft(
            title: "flaky test note",
            payload: .semantic(instruction: "x", fewShots: []),
            body: "x"
        )
        #expect(SuggestionFilter.signal(for: finding, feedback: []) == .reject)
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
        #expect(SuggestionFilter.signal(for: finding, feedback: [up]) == .endorse)
        #expect(
            SuggestionFilter.keepJobRule(draft: draft, findings: [finding], feedback: [up]) == true
        )
        #expect(SuggestionFilter.contextBody(findings: [finding], feedback: [up])?.contains("flaky") == true)
        let wouldNot = RiskAssessment(
            verdict: .needsHuman,
            mode: .shadow,
            score: 5,
            appetite: 1,
            reasons: [],
            safeUnread: false
        )
        #expect(
            SuggestionFilter.keepJobRule(
                draft: draft,
                findings: [finding],
                feedback: [],
                risk: wouldNot
            ) == false
        )
        let asRule = FindingFeedback(
            id: 2,
            findingID: finding.id,
            jobID: finding.jobID,
            ts: Date(),
            verdict: .shouldBeRule
        )
        #expect(SuggestionFilter.signal(for: finding, feedback: [asRule]) == .endorse)
    }

    @Test
    func ruleProposalNeedsTwoDistinctJobs() {
        let first = sampleFinding(title: "Silent hop errors", verdict: .keep, jobID: JobID("job-1"))
        let second = sampleFinding(title: "silent  hop errors", verdict: .keep, jobID: JobID("job-2"))
        let up1 = FindingFeedback(
            id: 1,
            findingID: first.id,
            jobID: first.jobID,
            ts: Date(),
            verdict: .agree,
            reaction: .thumbsUp
        )
        let up2 = FindingFeedback(
            id: 2,
            findingID: second.id,
            jobID: second.jobID,
            ts: Date(),
            verdict: .shouldBeRule
        )
        #expect(
            SuggestionFilter.enoughRuleEndorsements(
                titles: ["Silent hop errors"],
                findings: [first],
                feedback: [up1]
            ) == false
        )
        #expect(
            SuggestionFilter.endorsingJobIDs(
                titles: ["Silent hop errors"],
                findings: [first, first],
                feedback: [up1]
            ).count == 1
        )
        #expect(
            SuggestionFilter.enoughRuleEndorsements(
                titles: ["Silent hop errors"],
                findings: [first, second],
                feedback: [up1, up2]
            )
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
    func jobLevelLabelNeverAutoSuppressesAFinding() {
        let finding = sampleFinding(title: "Silent hop errors", verdict: .keep)
        let draft = MinedRuleDraft(
            title: "Silent hop errors",
            payload: .semantic(instruction: "log hop failures", fewShots: []),
            body: "log hop failures"
        )
        let up = FindingFeedback(
            id: 1,
            findingID: finding.id,
            jobID: finding.jobID,
            ts: Date(),
            verdict: .agree,
            reaction: .thumbsUp
        )
        let wouldMerge = RiskAssessment(
            verdict: .needsHuman,
            mode: .shadow,
            score: 3,
            appetite: 1,
            reasons: [],
            safeUnread: true
        )
        let wouldNot = RiskAssessment(
            verdict: .needsHuman,
            mode: .shadow,
            score: 3,
            appetite: 1,
            reasons: [],
            safeUnread: false
        )
        #expect(
            SuggestionFilter.keepJobRule(
                draft: draft,
                findings: [finding],
                feedback: [up],
                risk: wouldMerge
            ) == true
        )
        #expect(
            SuggestionFilter.keepJobRule(
                draft: draft,
                findings: [finding],
                feedback: [up],
                risk: wouldNot
            ) == true
        )
        #expect(
            SuggestionFilter.keepJobRule(
                draft: draft,
                findings: [finding],
                feedback: [],
                risk: wouldMerge
            ) == false
        )
        let down = FindingFeedback(
            id: 2,
            findingID: finding.id,
            jobID: finding.jobID,
            ts: Date(),
            verdict: .disagree,
            reaction: .thumbsDown
        )
        #expect(
            SuggestionFilter.keepJobRule(
                draft: draft,
                findings: [finding],
                feedback: [down],
                risk: wouldMerge
            ) == false
        )
    }

    @Test
    func wouldNotMinesKeptErrorsWithoutThumbs() {
        let error = sampleFinding(title: "Hardcoded secret", verdict: .keep, severity: .error)
        let warning = sampleFinding(title: "noisy log", verdict: .keep, severity: .warning)
        let dropped = sampleFinding(title: "flaky test note", verdict: .drop, severity: .error)
        let wouldNot = RiskAssessment(
            verdict: .needsHuman,
            mode: .shadow,
            score: 5,
            appetite: 1,
            reasons: [],
            safeUnread: false
        )
        #expect(
            SuggestionFilter.keepJobRule(
                draft: MinedRuleDraft(
                    title: "Hardcoded secret",
                    payload: .semantic(instruction: "x", fewShots: []),
                    body: "x"
                ),
                findings: [error],
                feedback: [],
                risk: wouldNot
            ) == true
        )
        #expect(
            SuggestionFilter.keepJobRule(
                draft: MinedRuleDraft(
                    title: "noisy log",
                    payload: .semantic(instruction: "x", fewShots: []),
                    body: "x"
                ),
                findings: [warning],
                feedback: [],
                risk: wouldNot
            ) == false
        )
        #expect(
            SuggestionFilter.keepJobRule(
                draft: MinedRuleDraft(
                    title: "flaky test note",
                    payload: .semantic(instruction: "x", fewShots: []),
                    body: "x"
                ),
                findings: [dropped],
                feedback: [],
                risk: wouldNot
            ) == false
        )
    }

    @Test
    func autoApproveThenUnsafeIsHighestWeight() {
        let highest = MergeIntentContext.from(
            RiskAssessment(
                verdict: .autoApprove,
                mode: .shadow,
                score: 1,
                appetite: 1,
                reasons: [],
                safeUnread: false
            )
        )
        #expect(highest?.wouldMerge == false)
        #expect(highest?.weight == "highest")
        let normal = MergeIntentContext.from(
            RiskAssessment(
                verdict: .needsHuman,
                mode: .shadow,
                score: 4,
                appetite: 1,
                reasons: [],
                safeUnread: false
            )
        )
        #expect(normal?.weight == "normal")
        #expect(MergeIntentContext.from(
            RiskAssessment(
                verdict: .autoApprove,
                mode: .shadow,
                score: 1,
                appetite: 1,
                reasons: []
            )
        ) == nil)
    }

    @Test
    func stagedFeedbackJSONPutsMergeIntentBesideFindingFeedback() throws {
        let object = try #require(
            SuggestionFilter.stagedFeedbackJSON(
                findingFeedback: [["finding_id": "fnd_1", "verdict": "agree", "ts": "t"]],
                risk: RiskAssessment(
                    verdict: .autoApprove,
                    mode: .enforce,
                    score: 1,
                    appetite: 1,
                    reasons: [],
                    safeUnread: false
                )
            )
        )
        #expect((object["finding_feedback"] as? [[String: String]])?.count == 1)
        let intent = try #require(object["merge_intent"] as? [String: Any])
        #expect(intent["would_merge"] as? Bool == false)
        #expect(intent["safe_unread"] as? Bool == false)
        #expect(intent["weight"] as? String == "highest")
        #expect(intent["risk_verdict"] as? String == "auto_approve")
        #expect(SuggestionFilter.stagedFeedbackJSON(findingFeedback: [], risk: nil) == nil)
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

    @Test
    func suggestionJudgeDuplicateIdsKeepLast() {
        let candidates = [
            SuggestionCandidate(id: "sug_rule_0", kind: .rule, title: "t", body: "b"),
        ]
        let payload = """
        {"verdicts":[
          {"finding_id":"sug_rule_0","verdict":"drop","rationale":"first"},
          {"finding_id":"sug_rule_0","verdict":"keep","rationale":"last"}
        ]}
        """
        let kept = SuggestionJudge.apply(
            outcome: SuggestionJudge.parse(Data(payload.utf8)),
            candidates: candidates,
            fallbackIDs: []
        )
        #expect(kept.count == 1)
        #expect(kept[0].id == "sug_rule_0")
    }

    @Test
    func suggestionJudgeEventPayloadIncludesFailureReason() {
        let payload = SuggestionJudge.eventPayload(
            candidates: 13,
            kept: 13,
            result: SuggestionJudgeRunResult(
                outcome: .failed,
                containerName: "sugjudge",
                errorMessage: "missing_suggestion_judge_file",
                exitCode: 0
            )
        )
        #expect(payload.contains("\"candidates\":13"))
        #expect(payload.contains("\"judged\":false"))
        #expect(payload.contains("missing_suggestion_judge_file"))
        #expect(payload.contains("\"exit_code\":0"))
    }
}

private func sampleFinding(
    title: String,
    verdict: JudgeVerdict,
    severity: Severity = .warning,
    jobID: JobID = JobID("job-1")
) -> Finding {
    Finding(
        id: FindingID.generate(),
        jobID: jobID,
        phase: .agent,
        severity: severity,
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
