import Testing
@testable import GegenlesenCore

@Suite
struct JobStateMachineTests {
    @Test
    func legalTransitions() throws {
        let cases: [(JobStatus, JobStateMachine.Event, JobStatus)] = [
            (.queued, .dequeued, .unpacking),
            (.queued, .cancel, .cancelled),
            (.queued, .processRestarted, .failed),
            (.unpacking, .unpackOK, .identifying),
            (.unpacking, .unpackFailed("bad"), .failed),
            (.identifying, .identifyOK, .selectingRules),
            (.identifying, .identifyFailed("no_change_set"), .failed),
            (.selectingRules, .rulesOK, .deterministic),
            (.selectingRules, .rulesFailed("boom"), .failed),
            (.deterministic, .deterministicDone(newWork: false, skipAgent: false), .succeeded),
            (.deterministic, .deterministicDone(newWork: false, skipAgent: true), .succeeded),
            (.deterministic, .deterministicDone(newWork: true, skipAgent: true), .succeeded),
            (.deterministic, .deterministicDone(newWork: true, skipAgent: false), .reviewing),
            (.deterministic, .deterministicTimeout, .failed),
            (.reviewing, .reviewOK(validFindingCount: 0), .succeeded),
            (.reviewing, .reviewOK(validFindingCount: 3), .judging),
            (.reviewing, .reviewFailed("timeout"), .failed),
            (.judging, .judgeFinished, .succeeded),
            (.unpacking, .cancel, .cancelled),
            (.identifying, .cancel, .cancelled),
            (.selectingRules, .cancel, .cancelled),
            (.deterministic, .cancel, .cancelled),
            (.reviewing, .cancel, .cancelled),
            (.judging, .cancel, .cancelled),
        ]
        for item in cases {
            let next = try JobStateMachine.transition(from: item.0, item.1)
            #expect(next == item.2, "\(item.0.rawValue) + \(String(describing: item.1))")
        }
    }

    @Test
    func illegalTransitionsThrow() {
        let cases: [(JobStatus, JobStateMachine.Event)] = [
            (.queued, .unpackOK),
            (.unpacking, .dequeued),
            (.succeeded, .cancel),
            (.failed, .cancel),
            (.cancelled, .dequeued),
            (.judging, .reviewOK(validFindingCount: 1)),
            (.deterministic, .identifyOK),
        ]
        for item in cases {
            #expect(throws: JobStateMachine.IllegalTransition.self) {
                _ = try JobStateMachine.transition(from: item.0, item.1)
            }
        }
    }
}
