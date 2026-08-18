public enum ReviewContainers: Sendable {
    public static func slot(_ jobID: JobID, _ slot: ReviewerSlot) -> String {
        let suffix = slot == .modelA ? "a" : "b"
        return "meister-review-\(jobID.rawValue)-\(suffix)"
    }

    public static func judge(_ jobID: JobID) -> String {
        "meister-judge-\(jobID.rawValue)"
    }

    public static func all(_ jobID: JobID) -> [String] {
        [
            slot(jobID, .modelA),
            slot(jobID, .modelB),
            judge(jobID),
        ]
    }
}
