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

public enum SuggestionJudge: Sendable {
    public static let prompt = """
        # Meister suggestion judge

        You filter proposed house rules and context notes. Default is DROP.
        These are not review findings. Keep only what should apply to FUTURE
        changes, not a recap of this one PR.

        Read .meister/suggestion-judge-input.json. Echo each candidate.id
        as finding_id.

        Keep a rule only if it is a reusable instruction (logger, secrets,
        API shape, a class of bug). Drop one-off defects, restated findings,
        and weak test-coverage notes.

        Keep a context note only if it is durable project knowledge
        (architecture, house style). Drop a bullet list of this job's findings.

        Write .meister/suggestion-judge.json:
          { "verdicts": [ { "finding_id", "verdict", "rationale" } ] }

        verdict is keep or drop. Do not invent candidates.
        Do not modify any file except .meister/suggestion-judge.json.
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
        let meister = workspace.appendingPathComponent(".meister", isDirectory: true)
        try FileManager.default.createDirectory(at: meister, withIntermediateDirectories: true)
        try prompt.write(
            to: meister.appendingPathComponent("prompt-suggestion-judge.md"),
            atomically: true,
            encoding: .utf8
        )
        try data.write(
            to: meister.appendingPathComponent("suggestion-judge-input.json"),
            options: .atomic
        )
    }

    /// Model keep only. If the judge file is missing, fall back to host-endorsed ids.
    public static func keptIDs(
        from outcome: JudgeOutcome,
        candidates: [SuggestionCandidate],
        fallbackIDs: Set<String>
    ) -> Set<String> {
        switch outcome {
        case .containerFailed, .invalidFile:
            return fallbackIDs
        case .verdicts(let file):
            let byID = Dictionary(uniqueKeysWithValues: file.verdicts.map { ($0.findingID.rawValue, $0) })
            return Set(candidates.compactMap { item in
                byID[item.id]?.verdict == .keep ? item.id : nil
            })
        }
    }
}

public protocol SuggestionJudging: Sendable {
    func runSuggestionJudge(job: Job, workspace: Workspace) async -> JudgeRunResult
}
