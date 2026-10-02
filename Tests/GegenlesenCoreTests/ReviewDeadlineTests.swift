import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct ReviewDeadlineTests {
    @Test
    func shortBudgetLeavesTimeForCurrentStage() {
        ReviewDeadline.$expiresAt.withValue(.now + .seconds(10)) {
            let allowed = ReviewDeadline.timeout(.seconds(120), reserving: .seconds(120))
            #expect(allowed > .seconds(4))
            #expect(allowed <= .seconds(5))
        }
    }

    @Test
    func absoluteTimeoutCancelsOperation() async throws {
        let started = ContinuousClock.now
        await #expect(throws: ReviewDeadlineExceeded.self) {
            try await ReviewDeadline.run(timeout: .milliseconds(100)) {
                try await Task.sleep(for: .seconds(30))
                return true
            }
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test
    func completedOperationCancelsTimeout() async throws {
        let result = try await ReviewDeadline.run(timeout: .seconds(30)) { 42 }
        #expect(result == 42)
    }
}
