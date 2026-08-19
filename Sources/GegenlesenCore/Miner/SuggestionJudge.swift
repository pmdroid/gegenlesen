import Foundation

public struct SuggestionCandidate: Sendable, Equatable {
    public var id: String
    public var kind: LearningKind
    public var title: String
    public var body: String

    public init(id: String, kind: LearningKind, title: String, body: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
    }
}

public struct SuggestionVerdict: Sendable, Equatable {
    public var id: String
    public var verdict: JudgeDecision
    public var rationale: String
    public var rewriteTitle: String?
    public var rewriteBody: String?

    public init(
        id: String,
        verdict: JudgeDecision,
        rationale: String,
        rewriteTitle: String? = nil,
        rewriteBody: String? = nil
    ) {
        self.id = id
        self.verdict = verdict
        self.rationale = rationale
        self.rewriteTitle = rewriteTitle
        self.rewriteBody = rewriteBody
    }
}

public enum SuggestionJudgeOutcome: Sendable, Equatable {
    case verdicts([SuggestionVerdict])
    case failed
}

public struct SuggestionJudgeRunResult: Sendable {
    public var outcome: SuggestionJudgeOutcome
    public var transcript: Data
    public var containerName: String

    public init(
        outcome: SuggestionJudgeOutcome,
        transcript: Data = Data(),
        containerName: String
    ) {
        self.outcome = outcome
        self.transcript = transcript
        self.containerName = containerName
    }
}

public enum SuggestionJudge: Sendable {
    public static let prompt = """
        # Gegenlesen suggestion judge

        You filter proposed house rules and context notes. Decide FIRST.
        Default is DROP. These are not review findings.

        Read .gegenlesen/suggestion-judge-input.json. Echo each candidate.id
        as finding_id.

        Keep a rule only if it is a reusable instruction for FUTURE changes
        (logger, secrets, API shape, a class of bug). Drop one-off defects,
        restated findings, and weak test-coverage notes.

        Keep a context note only if it is durable project knowledge
        (architecture, house style). Drop a bullet list of this job's findings.

        If and only if verdict is keep, you MAY add rewrite {title, body}:
        make the text generic, not tied to this PR's file names or tickets,
        and add missing house-style context when the draft is too narrow.
        Do not invent policy the evidence does not support.

        Write .gegenlesen/suggestion-judge.json:
          { "verdicts": [ { "finding_id", "verdict", "rationale", "rewrite"? } ] }

        rewrite is optional: { "title", "body" }.
        Do not invent candidates.
        Do not modify any file except .gegenlesen/suggestion-judge.json.
        """

    public static func writeInput(_ candidates: [SuggestionCandidate], workspace: URL) throws {
        let rows: [[String: Any]] = candidates.map { item in
            [
                "id": item.id,
                "kind": item.kind.rawValue,
                "title": item.title,
                "body": item.body,
            ]
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["candidates": rows],
            options: [.prettyPrinted, .sortedKeys]
        )
        let gegenlesen = workspace.appendingPathComponent(".gegenlesen", isDirectory: true)
        try FileManager.default.createDirectory(at: gegenlesen, withIntermediateDirectories: true)
        try prompt.write(
            to: gegenlesen.appendingPathComponent("prompt-suggestion-judge.md"),
            atomically: true,
            encoding: .utf8
        )
        try data.write(
            to: gegenlesen.appendingPathComponent("suggestion-judge-input.json"),
            options: .atomic
        )
    }

    public static func parse(_ data: Data) -> SuggestionJudgeOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["verdicts"] as? [Any]
        else {
            return .failed
        }
        var rows: [SuggestionVerdict] = []
        for item in raw.prefix(200) {
            guard let object = item as? [String: Any],
                  let id = object["finding_id"] as? String, !id.isEmpty,
                  let verdictRaw = object["verdict"] as? String,
                  let verdict = JudgeDecision(rawValue: verdictRaw),
                  let rationale = object["rationale"] as? String
            else {
                return .failed
            }
            var rewriteTitle: String?
            var rewriteBody: String?
            if let rewrite = object["rewrite"] as? [String: Any] {
                rewriteTitle = nonempty(rewrite["title"] as? String)
                rewriteBody = nonempty(rewrite["body"] as? String)
            }
            if verdict != .keep {
                rewriteTitle = nil
                rewriteBody = nil
            }
            rows.append(
                SuggestionVerdict(
                    id: id,
                    verdict: verdict,
                    rationale: rationale,
                    rewriteTitle: rewriteTitle,
                    rewriteBody: rewriteBody
                )
            )
        }
        return .verdicts(rows)
    }

    /// Keep + optional rewrite. Judge file missing falls back to host-endorsed ids.
    public static func apply(
        outcome: SuggestionJudgeOutcome,
        candidates: [SuggestionCandidate],
        fallbackIDs: Set<String>
    ) -> [SuggestionCandidate] {
        switch outcome {
        case .failed:
            return candidates.filter { fallbackIDs.contains($0.id) }
        case .verdicts(let rows):
            let verdictByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            return candidates.compactMap { item in
                guard verdictByID[item.id]?.verdict == .keep else { return nil }
                return applying(verdictByID[item.id], to: item)
            }
        }
    }

    public static func applying(
        _ verdict: SuggestionVerdict?,
        to candidate: SuggestionCandidate
    ) -> SuggestionCandidate {
        var next = candidate
        if let title = verdict?.rewriteTitle, !title.isEmpty {
            next.title = title
        }
        if let body = verdict?.rewriteBody, !body.isEmpty {
            next.body = body
        }
        return next
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public protocol SuggestionJudging: Sendable {
    func runSuggestionJudge(job: Job, workspace: Workspace) async -> SuggestionJudgeRunResult
}
