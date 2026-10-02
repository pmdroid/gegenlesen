import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct DockerCancellationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GEGENLESEN_TEST_DOCKER_IMAGE"] != nil))
    func cancellationStopsRunningContainer() async throws {
        let image = try #require(ProcessInfo.processInfo.environment["GEGENLESEN_TEST_DOCKER_IMAGE"])
        let name = "gegenlesen-cancel-test-\(UUID().uuidString.lowercased())"
        let runner = DockerRunner()
        let task = Task {
            try await runner.run(DockerRequest(name: name, image: image, argv: ["sleep", "30"], network: "none", timeout: .seconds(60)))
        }
        try await Task.sleep(for: .seconds(1))
        let started = ContinuousClock.now
        task.cancel()
        let result = try await task.value
        #expect(result.timedOut)
        #expect(ContinuousClock.now - started < .seconds(5))
        let inspect = try DockerRunner.runDocker(path: runner.dockerPath, arguments: ["inspect", name])
        #expect(inspect.exitCode != 0)
    }

    @Test
    func expiredBudgetDoesNotStartDocker() async throws {
        let result = try await ReviewDeadline.$expiresAt.withValue(ContinuousClock.now - .seconds(1)) {
            try await DockerRunner(dockerPath: "/does/not/exist").run(DockerRequest(name: "expired", image: "test"))
        }
        #expect(result.timedOut)
        #expect(result.exitCode == 124)
    }
}
