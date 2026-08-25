import Foundation
import Testing
@testable import GegenlesenCore
@testable import GegenlesenDeterministic

@Suite
struct OperatorSuppressionTests {
    @Test
    func disagreeFingerprintsAreRepoScoped() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let fingerprint = Fingerprint.sha256(
                ruleID: RuleID("no-probe"),
                path: "Sources/A.swift",
                snippet: "eval(__gegenlesen_probe__)"
            )
            let home = try await insertFindingJob(
                store: store,
                repository: "github.com/acme/app",
                fingerprint: fingerprint,
                now: now
            )
            let other = try await insertFindingJob(
                store: store,
                repository: "github.com/acme/other",
                fingerprint: fingerprint,
                now: now
            )
            _ = try await store.applyFindingFeedback(
                finding: home,
                verdict: .disagree,
                reaction: .thumbsDown,
                comment: nil,
                now: now
            )
            _ = try await store.applyFindingFeedback(
                finding: other,
                verdict: .agree,
                reaction: .thumbsUp,
                comment: nil,
                now: now
            )

            let suppressed = try await store.suppressedFingerprints(repository: "github.com/acme/app")
            #expect(suppressed == [fingerprint])
            #expect(try await store.suppressedFingerprints(repository: "github.com/acme/other").isEmpty)
            #expect(try await store.suppressedFingerprints(repository: "github.com/acme/missing").isEmpty)
        }
    }

    @Test
    func thumbsUpAndClearedDisagreeDoNotSuppress() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let fingerprint = Fingerprint.sha256(
                ruleID: RuleID("no-probe"),
                path: "Sources/A.swift",
                snippet: "eval(__gegenlesen_probe__)"
            )
            let finding = try await insertFindingJob(
                store: store,
                repository: "github.com/acme/app",
                fingerprint: fingerprint,
                now: now
            )
            _ = try await store.applyFindingFeedback(
                finding: finding,
                verdict: .agree,
                reaction: .thumbsUp,
                comment: nil,
                now: now
            )
            #expect(try await store.suppressedFingerprints(repository: "github.com/acme/app").isEmpty)

            _ = try await store.applyFindingFeedback(
                finding: finding,
                verdict: .disagree,
                reaction: .thumbsDown,
                comment: nil,
                now: now
            )
            #expect(try await store.suppressedFingerprints(repository: "github.com/acme/app") == [fingerprint])

            let cleared = try await store.applyFindingFeedback(
                finding: finding,
                verdict: .disagree,
                reaction: .thumbsDown,
                comment: nil,
                now: now
            )
            #expect(cleared == .cleared)
            #expect(try await store.suppressedFingerprints(repository: "github.com/acme/app").isEmpty)
        }
    }

    @Test
    func applyDropsMatchingFingerprint() {
        let fingerprint = Fingerprint.sha256(
            ruleID: RuleID("no-probe"),
            path: "Sources/A.swift",
            snippet: "eval(__gegenlesen_probe__)"
        )
        var finding = suppressionFinding()
        finding.ruleID = RuleID("no-probe")
        finding.filePath = "Sources/A.swift"
        finding.snippet = "eval(__gegenlesen_probe__)"
        finding.fingerprint = fingerprint
        finding.judgeVerdict = .keep
        let dropped = OperatorSuppression.apply(finding, suppressed: [fingerprint])
        #expect(dropped.judgeVerdict == .drop)
        #expect(dropped.judgeRationale == OperatorSuppression.dropReason)
        let kept = OperatorSuppression.apply(finding, suppressed: [])
        #expect(kept.judgeVerdict == .keep)
    }

    @Test
    func stampMechanicalPreservesOperatorDrop() {
        var finding = suppressionFinding()
        finding.judgeVerdict = .drop
        finding.judgeRationale = OperatorSuppression.dropReason
        let stamped = JudgeHandoff.stampMechanical([finding], commandRuleIDs: [])
        #expect(stamped[0].judgeVerdict == .drop)
        #expect(stamped[0].judgeRationale == OperatorSuppression.dropReason)
    }

    @Test
    func skipAgentSecondReviewDropsDisagreedHit() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await store.insertRule(
                sampleRule(
                    id: "no-probe",
                    languages: ["swift"],
                    globs: ["**/*.swift"],
                    payload: .regex(
                        pattern: NSRegularExpression.escapedPattern(for: "eval(__gegenlesen_probe__)"),
                        flags: nil,
                        message: "probe"
                    )
                )
            )
            try await withProbeRepo(dir: dir) { archive in
                let first = queuedRepoJob(repository: "github.com/acme/app")
                try await store.insertJob(first)
                try FileManager.default.copyItem(
                    at: archive,
                    to: store.blobs.archiveURL(jobID: first.id.rawValue)
                )
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: true,
                    deterministic: DeterministicEngine(),
                    reviewer: nil
                )
                try await pipeline.run(jobID: first.id)
                let firstJob = try #require(try await store.job(id: first.id))
                #expect(firstJob.status == .succeeded)
                let firstFindings = try await store.findings(jobID: first.id)
                let kept = firstFindings.filter { $0.judgeVerdict != .drop }
                #expect(kept.count == 1)
                #expect(kept[0].ruleID == RuleID("no-probe"))

                _ = try await store.applyFindingFeedback(
                    finding: kept[0],
                    verdict: .disagree,
                    reaction: .thumbsDown,
                    comment: nil
                )

                let second = queuedRepoJob(repository: "github.com/acme/app")
                try await store.insertJob(second)
                try FileManager.default.copyItem(
                    at: archive,
                    to: store.blobs.archiveURL(jobID: second.id.rawValue)
                )
                try await pipeline.run(jobID: second.id)
                let secondJob = try #require(try await store.job(id: second.id))
                #expect(secondJob.status == .succeeded)
                let secondFindings = try await store.findings(jobID: second.id)
                #expect(secondFindings.count == 1)
                #expect(secondFindings[0].judgeVerdict == .drop)
                #expect(secondFindings[0].judgeRationale == OperatorSuppression.dropReason)
                #expect(secondFindings.filter { $0.judgeVerdict != .drop }.isEmpty)
            }
        }
    }

    @Test
    func skipAgentSecondReviewKeepsAfterThumbsUp() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            try await store.insertRule(
                sampleRule(
                    id: "no-probe",
                    languages: ["swift"],
                    globs: ["**/*.swift"],
                    payload: .regex(
                        pattern: NSRegularExpression.escapedPattern(for: "eval(__gegenlesen_probe__)"),
                        flags: nil,
                        message: "probe"
                    )
                )
            )
            try await withProbeRepo(dir: dir) { archive in
                let first = queuedRepoJob(repository: "github.com/acme/app")
                try await store.insertJob(first)
                try FileManager.default.copyItem(
                    at: archive,
                    to: store.blobs.archiveURL(jobID: first.id.rawValue)
                )
                let pipeline = ReviewPipeline(
                    store: store,
                    skipAgent: true,
                    deterministic: DeterministicEngine(),
                    reviewer: nil
                )
                try await pipeline.run(jobID: first.id)
                let kept = try await store.findings(jobID: first.id).filter { $0.judgeVerdict != .drop }
                #expect(kept.count == 1)
                _ = try await store.applyFindingFeedback(
                    finding: kept[0],
                    verdict: .agree,
                    reaction: .thumbsUp,
                    comment: nil
                )

                let second = queuedRepoJob(repository: "github.com/acme/app")
                try await store.insertJob(second)
                try FileManager.default.copyItem(
                    at: archive,
                    to: store.blobs.archiveURL(jobID: second.id.rawValue)
                )
                try await pipeline.run(jobID: second.id)
                let secondKept = try await store.findings(jobID: second.id).filter { $0.judgeVerdict != .drop }
                #expect(secondKept.count == 1)
            }
        }
    }
}

private func suppressionFinding() -> Finding {
    Finding(
        id: FindingID.generate(),
        jobID: JobID.generate(),
        ruleID: RuleID("no-probe"),
        phase: .deterministic,
        severity: .warning,
        title: "probe",
        message: "probe",
        filePath: "Sources/A.swift",
        startLine: 1,
        endLine: 1,
        snippet: "eval(__gegenlesen_probe__)",
        judgeVerdict: .keep,
        createdAt: Date()
    )
}

private func insertFindingJob(
    store: Store,
    repository: String,
    fingerprint: String,
    now: Date
) async throws -> Finding {
    let job = Job(
        id: JobID.generate(),
        createdAt: now,
        updatedAt: now,
        status: .succeeded,
        scope: .full,
        repository: repository,
        reviewerAModelID: "a",
        reviewerBModelID: "b",
        judgeModelID: "j"
    )
    try await store.insertJob(job)
    let finding = Finding(
        id: FindingID.generate(at: now),
        jobID: job.id,
        ruleID: RuleID("no-probe"),
        phase: .deterministic,
        severity: .warning,
        title: "probe",
        message: "probe",
        filePath: "Sources/A.swift",
        startLine: 1,
        endLine: 1,
        snippet: "eval(__gegenlesen_probe__)",
        judgeVerdict: .keep,
        fingerprint: fingerprint,
        createdAt: now
    )
    try await store.insertParsedFindings([finding])
    return finding
}

private func queuedRepoJob(repository: String) -> Job {
    let now = Date()
    return Job(
        id: JobID.generate(),
        createdAt: now,
        updatedAt: now,
        status: .queued,
        scope: .full,
        repository: repository,
        reviewerAModelID: "anthropic/claude-sonnet-4-5",
        reviewerBModelID: "openai/gpt-5.2",
        judgeModelID: "anthropic/claude-sonnet-4-5"
    )
}

private func withProbeRepo(dir: URL, _ body: (URL) async throws -> Void) async throws {
    try await withTempDir("suppress-pack") { repo in
        try writeFile("Sources/A.swift", "eval(__gegenlesen_probe__)\n", in: repo)
        try writeFile(
            ".gegenlesen/diff.patch",
            """
            diff --git a/Sources/A.swift b/Sources/A.swift
            new file mode 100644
            --- /dev/null
            +++ b/Sources/A.swift
            @@ -0,0 +1 @@
            +eval(__gegenlesen_probe__)
            """,
            in: repo
        )
        try writeFile(".gegenlesen/repository", "github.com/acme/app\n", in: repo)
        let archive = dir.appendingPathComponent("change-\(UUID().uuidString).tar.gz")
        try gzipTarCreate(from: repo, to: archive)
        try await body(archive)
    }
}
