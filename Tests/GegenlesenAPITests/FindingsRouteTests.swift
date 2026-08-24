import Foundation
import Testing
import VaporTesting
@testable import GegenlesenAPI
@testable import GegenlesenCore

@Suite
struct FindingsRouteTests {
    @Test
    func reactionAliasesAndToggle() async throws {
        try await withGegenlesenApp { app in
            let finding = try await seedFinding(app)
            for alias in ["👍", "+1", "thumbs_up"] {
                let created = try await postFeedback(app, finding.id.rawValue, json: #"{"reaction":"\#(alias)"}"#)
                #expect(created.status == .created)
                let body = try jsonObject(created)
                #expect(body["verdict"] as? String == "agree")
                #expect(body["reaction"] as? String == "thumbs_up")
                #expect(Set(body.keys) == feedbackKeys)

                try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/feedback") {
                    res async throws in
                    #expect(res.status == .ok)
                    let listed = try jsonObject(res)
                    #expect(Set(listed.keys) == ["feedback"])
                    let rows = try #require(listed["feedback"] as? [[String: Any]])
                    #expect(rows.count == 1)
                    #expect(rows[0]["reaction"] as? String == "thumbs_up")
                }

                let cleared = try await postFeedback(app, finding.id.rawValue, json: #"{"reaction":"\#(alias)"}"#)
                #expect(cleared.status == .noContent)
                #expect(cleared.body.readableBytes == 0)
                try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/feedback") {
                    res async throws in
                    let listed = try jsonObject(res)
                    let rows = try #require(listed["feedback"] as? [[String: Any]])
                    #expect(rows.isEmpty)
                }
            }

            for alias in ["👎", "-1", "thumbs_down"] {
                let created = try await postFeedback(app, finding.id.rawValue, json: #"{"reaction":"\#(alias)"}"#)
                #expect(created.status == .created)
                #expect(try jsonObject(created)["verdict"] as? String == "disagree")
                _ = try await postFeedback(app, finding.id.rawValue, json: #"{"reaction":"\#(alias)"}"#)
            }
        }
    }

    @Test
    func switchingReactionReplacesPriorVote() async throws {
        try await withGegenlesenApp { app in
            let finding = try await seedFinding(app)
            _ = try await postFeedback(app, finding.id.rawValue, json: #"{"reaction":"thumbs_up"}"#)
            let down = try await postFeedback(app, finding.id.rawValue, json: #"{"reaction":"thumbs_down"}"#)
            #expect(down.status == .created)
            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/feedback") {
                res async throws in
                let listed = try jsonObject(res)
                let rows = try #require(listed["feedback"] as? [[String: Any]])
                #expect(rows.count == 1)
                #expect(rows[0]["verdict"] as? String == "disagree")
                #expect(rows[0]["reaction"] as? String == "thumbs_down")
            }
        }
    }

    @Test
    func unknownEmojiIsBadRequest() async throws {
        try await withGegenlesenApp { app in
            let finding = try await seedFinding(app)
            let res = try await postFeedback(app, finding.id.rawValue, json: #"{"reaction":"👀"}"#)
            #expect(res.status == .badRequest)
            try assertError(res, code: "bad_request")
        }
    }

    @Test
    func shouldBeRuleInsertsDisabledSuggestedRule() async throws {
        try await withGegenlesenApp { app in
            let finding = try await seedFinding(app, filePath: "Sources/Auth/Session.swift")
            let res = try await postFeedback(
                app,
                finding.id.rawValue,
                json: #"{"verdict":"should_be_rule","comment":"ban print in Auth"}"#
            )
            #expect(res.status == .created)
            let body = try jsonObject(res)
            #expect(body["verdict"] as? String == "should_be_rule")
            let ruleID = try #require(body["suggested_rule_id"] as? String)

            try await app.testing().test(.GET, "/api/rules/\(ruleID)") { res async throws in
                #expect(res.status == .ok)
                let rule = try jsonObject(res)
                #expect(rule["enabled"] as? Bool == false)
                #expect(rule["provenance"] as? String == "suggested")
                #expect(rule["kind"] as? String == "semantic")
                #expect(rule["title"] as? String == finding.title)
                let globs = try #require(rule["path_globs"] as? [String])
                #expect(globs == ["**/*.swift"])
                let languages = try #require(rule["languages"] as? [String])
                #expect(languages == ["swift"])
                let payload = try #require(rule["payload"] as? [String: Any])
                let instruction = try #require(payload["instruction"] as? String)
                #expect(instruction.contains(finding.title))
                #expect(instruction.contains(finding.message))
                #expect(instruction.contains("ban print in Auth"))
            }

            let again = try await postFeedback(
                app,
                finding.id.rawValue,
                json: #"{"verdict":"should_be_rule","comment":"still ban print"}"#
            )
            #expect(again.status == .ok)
            #expect(try jsonObject(again)["suggested_rule_id"] as? String == ruleID)
            try await app.testing().test(.GET, "/api/rules?provenance=suggested") { res async throws in
                let body = try jsonObject(res)
                let rules = try #require(body["rules"] as? [[String: Any]])
                #expect(rules.filter { $0["id"] as? String == ruleID }.count == 1)
                #expect(rules.filter { ($0["provenance"] as? String) == "suggested" }.count == 1)
                let instruction = try #require(
                    (rules.first?["payload"] as? [String: Any])?["instruction"] as? String
                )
                #expect(instruction.contains("still ban print"))
            }
        }
    }

    @Test
    func shouldBeRuleWithoutPathUsesStarLanguage() async throws {
        try await withGegenlesenApp { app in
            let finding = try await seedFinding(app, filePath: nil)
            let res = try await postFeedback(
                app,
                finding.id.rawValue,
                json: #"{"verdict":"should_be_rule"}"#
            )
            #expect(res.status == .created)
            let ruleID = try #require(try jsonObject(res)["suggested_rule_id"] as? String)
            try await app.testing().test(.GET, "/api/rules/\(ruleID)") { res async throws in
                let rule = try jsonObject(res)
                #expect(rule["languages"] as? [String] == ["*"])
                #expect(rule["path_globs"] as? [String] == ["**/*"])
            }
        }
    }

    @Test
    func commentsAccumulateAndLatestVerdictWins() async throws {
        try await withGegenlesenApp { app in
            let finding = try await seedFinding(app)
            _ = try await postFeedback(app, finding.id.rawValue, json: #"{"verdict":"agree"}"#)
            _ = try await postFeedback(app, finding.id.rawValue, json: #"{"verdict":"comment","comment":"first"}"#)
            _ = try await postFeedback(app, finding.id.rawValue, json: #"{"verdict":"comment","comment":"second"}"#)
            _ = try await postFeedback(app, finding.id.rawValue, json: #"{"verdict":"disagree","comment":"fp"}"#)

            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/feedback") {
                res async throws in
                let listed = try jsonObject(res)
                let rows = try #require(listed["feedback"] as? [[String: Any]])
                #expect(rows.count == 4)
                let comments = rows.filter { $0["verdict"] as? String == "comment" }
                #expect(comments.count == 2)
                let current = rows.reversed().first { ($0["verdict"] as? String) != "comment" }
                #expect(current?["verdict"] as? String == "disagree")
            }
        }
    }

    @Test
    func thumbsUpOnDroppedFindingRecordsEndorse() async throws {
        try await withGegenlesenApp { app in
            let finding = try await seedFinding(app, judgeVerdict: .drop)
            let res = try await postFeedback(app, finding.id.rawValue, json: #"{"reaction":"thumbs_up"}"#)
            #expect(res.status == .created)
            let body = try jsonObject(res)
            #expect(body["verdict"] as? String == "agree")
            #expect(body["reaction"] as? String == "thumbs_up")

            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)") { res async throws in
                #expect(res.status == .ok)
                let job = try jsonObject(res)
                let findings = try #require(job["findings"] as? [[String: Any]])
                #expect(findings.count == 1)
                #expect(findings[0]["judge_verdict"] as? String == "drop")
            }

            let asRule = try await postFeedback(
                app,
                finding.id.rawValue,
                json: #"{"verdict":"should_be_rule"}"#
            )
            #expect(asRule.status == .created)
            #expect(try jsonObject(asRule)["verdict"] as? String == "should_be_rule")
        }
    }

    @Test
    func unknownFindingIsNotFound() async throws {
        try await withGegenlesenApp { app in
            let res = try await postFeedback(app, "fnd_missing", json: #"{"verdict":"agree"}"#)
            #expect(res.status == .notFound)
            try assertError(res, code: "not_found")
        }
    }

    @Test
    func eventsAndTranscript() async throws {
        try await withGegenlesenApp { app in
            let finding = try await seedFinding(app)
            try await app.gegenlesenStore.appendEvent(jobID: finding.jobID, level: .info, message: "reviewing")
            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/events") {
                res async throws in
                #expect(res.status == .ok)
                let body = try jsonObject(res)
                #expect(Set(body.keys) == ["events"])
                let events = try #require(body["events"] as? [[String: Any]])
                #expect(events.contains { $0["message"] as? String == "reviewing" })
            }

            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/transcript") {
                res async throws in
                #expect(res.status == .badRequest)
                try assertError(res, code: "bad_request")
            }
            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/transcript?phase=bogus") {
                res async throws in
                #expect(res.status == .badRequest)
            }
            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/transcript?phase=mine") {
                res async throws in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/transcript?phase=suggestion_judge") {
                res async throws in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/transcript?phase=review_a") {
                res async throws in
                #expect(res.status == .notFound)
            }

            let url = app.gegenlesenStore.blobs.transcriptURL(jobID: finding.jobID.rawValue, phase: "review")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"text":"ANTHROPIC_API_KEY=sk-ant-api03-SUPERSECRETVALUE0001"}"#.utf8).write(to: url)

            try await app.testing().test(.GET, "/api/jobs/\(finding.jobID.rawValue)/transcript?phase=review_a") {
                res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.subType == "x-ndjson")
                #expect(!res.body.string.contains("SUPERSECRETVALUE0001"))
                #expect(res.body.string.contains("[REDACTED]"))
            }
        }
    }
}

private let feedbackKeys: Set<String> = [
    "id", "finding_id", "job_id", "ts", "verdict", "reaction", "comment", "suggested_rule_id",
]

private func seedFinding(
    _ app: Application,
    filePath: String? = "Sources/Auth/Session.swift",
    judgeVerdict: JudgeVerdict? = nil
) async throws -> Finding {
    let now = Date()
    let job = Job(
        id: JobID.generate(),
        createdAt: now,
        updatedAt: now,
        status: .succeeded,
        scope: .full,
        title: "auth",
        reviewerAModelID: "a",
        reviewerBModelID: "b",
        judgeModelID: "j"
    )
    try await app.gegenlesenStore.insertJob(job)
    let finding = Finding(
        id: FindingID.generate(at: now),
        jobID: job.id,
        ruleID: RuleID("use-project-logger"),
        phase: .agent,
        reviewerSlot: .modelA,
        severity: .warning,
        title: "Use the project logger, not print",
        message: "print is not allowed",
        filePath: filePath,
        startLine: 41,
        endLine: 41,
        snippet: "print(\"token\")",
        judgeVerdict: judgeVerdict,
        createdAt: now
    )
    try await app.gegenlesenStore.insertParsedFindings([finding])
    return finding
}

private func postFeedback(
    _ app: Application,
    _ findingID: String,
    json: String
) async throws -> TestingHTTPResponse {
    var captured: TestingHTTPResponse?
    try await app.testing().test(
        .POST,
        "/api/findings/\(findingID)/feedback",
        beforeRequest: { req in
            req.headers.contentType = .json
            req.body = .init(data: Data(json.utf8))
        },
        afterResponse: { res async in
            captured = res
        }
    )
    return try #require(captured)
}

private func assertError(_ res: TestingHTTPResponse, code: String) throws {
    let object = try jsonObject(res)
    let error = try #require(object["error"] as? [String: Any])
    #expect(error["code"] as? String == code)
    #expect(error["message"] is String)
    #expect(Set(object.keys) == ["error"])
}

private func jsonObject(_ res: TestingHTTPResponse) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(res.body.readableBytesView))
    return try #require(object as? [String: Any])
}
