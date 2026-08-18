public enum JobStateMachine: Sendable {
    public enum Event: Equatable, Sendable {
        case dequeued
        case unpackOK
        case unpackFailed(String)
        case identifyOK
        case identifyFailed(String)
        case rulesOK
        case rulesFailed(String)
        case deterministicDone(newWork: Bool, skipAgent: Bool)
        case deterministicTimeout
        case reviewOK(validFindingCount: Int)
        case reviewFailed(String)
        case judgeFinished
        case cancel
        case processRestarted
    }

    public struct IllegalTransition: Error, Equatable, Sendable {
        public var from: JobStatus
        public var event: Event

        public init(from: JobStatus, event: Event) {
            self.from = from
            self.event = event
        }
    }

    public static func transition(from: JobStatus, _ event: Event) throws -> JobStatus {
        switch (from, event) {
        case (.queued, .dequeued):
            return .unpacking
        case (.queued, .cancel):
            return .cancelled
        case (.queued, .processRestarted):
            return .failed
        case (.unpacking, .unpackOK):
            return .identifying
        case (.unpacking, .unpackFailed):
            return .failed
        case (.identifying, .identifyOK):
            return .selectingRules
        case (.identifying, .identifyFailed):
            return .failed
        case (.selectingRules, .rulesOK):
            return .deterministic
        case (.selectingRules, .rulesFailed):
            return .failed
        case (.deterministic, .deterministicDone(let newWork, let skipAgent)):
            if !newWork || skipAgent {
                return .succeeded
            }
            return .reviewing
        case (.deterministic, .deterministicTimeout):
            return .failed
        case (.reviewing, .reviewOK(let count)):
            return count == 0 ? .succeeded : .judging
        case (.reviewing, .reviewFailed):
            return .failed
        case (.judging, .judgeFinished):
            return .succeeded
        case (let status, .cancel) where !status.isTerminal:
            return .cancelled
        default:
            throw IllegalTransition(from: from, event: event)
        }
    }
}
