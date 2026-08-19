public enum ReviewContainers: Sendable {
    public static func slot(_ jobID: JobID, _ slot: ReviewerSlot) -> String {
        let suffix = slot == .modelA ? "a" : "b"
        return "gegenlesen-review-\(jobID.rawValue)-\(suffix)"
    }

    public static func judge(_ jobID: JobID) -> String {
        "gegenlesen-judge-\(jobID.rawValue)"
    }

    public static func command(_ jobID: JobID, _ ruleID: RuleID) -> String {
        "gegenlesen-cmd-\(jobID.rawValue)-\(ruleID.rawValue)"
    }

    public static func commandPrefix(_ jobID: JobID) -> String {
        "gegenlesen-cmd-\(jobID.rawValue)-"
    }

    public static func miner(_ jobID: JobID) -> String {
        "gegenlesen-mine-\(jobID.rawValue)"
    }

    public static func suggestionJudge(_ jobID: JobID) -> String {
        "gegenlesen-sugjudge-\(jobID.rawValue)"
    }

    public static func all(_ jobID: JobID) -> [String] {
        [
            slot(jobID, .modelA),
            slot(jobID, .modelB),
            judge(jobID),
            miner(jobID),
            suggestionJudge(jobID),
        ]
    }
}
