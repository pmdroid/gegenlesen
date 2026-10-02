import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct ReviewDegradeTests {
    @Test
    func invalidOutputDoesNotRepeatInvestigation() async throws {
        try await withTempDir("review-degrade-retry") { root in
            try writeFile("Sources/A.swift", "let x = 1\n", in: root)
            let docker = RetryFindingsDocker(workspace: root)
            let invocation = OpenCodeInvocation(
                docker: docker,
                image: "gegenlesen/opencode-runner:0.1.0",
                runnerConfig: repoRootFromAgentTests().appendingPathComponent("docker/opencode-runner")
            )
            let job = sampleJob()
            let result = await invocation.run(
                AgentReviewRequest(
                    job: job,
                    workspace: Workspace(root: root),
                    files: [
                        JobFile(jobID: job.id, path: "Sources/A.swift", status: .added, language: .swift),
                    ],
                    rules: [],
                    newWork: true
                )
            )
            #expect(result.failed == false)
            #expect(result.reviewDegraded)
            #expect(result.findings.isEmpty)
            let attempts = await docker.attempts
            #expect(attempts["a"] == 1)
        }
    }

    @Test(arguments: [true, false])
    func timedOutOutputsRemainPartialAndNeverRetry(validJSON: Bool) async throws {
        try await withTempDir("review-timeout") { root in
            try writeFile("Sources/A.swift", "let x = 1\n", in: root)
            let docker = PartialReviewDocker(workspace: root, validJSON: validJSON)
            let invocation = OpenCodeInvocation(docker: docker, image: "test", runnerConfig: repoRootFromAgentTests().appendingPathComponent("docker/opencode-runner"))
            let job = sampleJob()
            let result = await invocation.run(AgentReviewRequest(job: job, workspace: Workspace(root: root),
                files: [JobFile(jobID: job.id, path: "Sources/A.swift", status: .added)], rules: [], newWork: true))
            #expect(result.failed)
            #expect(result.errorMessage == "reviewer_timed_out")
            #expect(result.validFileCount == 0)
            #expect(await docker.calls == 2)
            #expect(result.findings.count == (validJSON ? 2 : 0))
            #expect(result.findings.allSatisfy { $0.judgeVerdict == .unavailable })
        }
    }

    @Test
    func sharedOutputCannotImpersonateBothReviewers() async throws {
        try await withTempDir("review-shared") { root in
            try writeFile("Sources/A.swift", "let x = 1\n", in: root)
            try writeFile(".gegenlesen/findings.json", #"{"findings":[]}"#, in: root)
            let docker = RecordingDocker(result: DockerResult(exitCode: 0))
            let invocation = OpenCodeInvocation(docker: docker, image: "test", runnerConfig: repoRootFromAgentTests().appendingPathComponent("docker/opencode-runner"))
            let job = sampleJob()
            let result = await invocation.run(AgentReviewRequest(job: job, workspace: Workspace(root: root),
                files: [JobFile(jobID: job.id, path: "Sources/A.swift", status: .added)], rules: [], newWork: true))
            #expect(result.failed)
            #expect(result.validFileCount == 0)
        }
    }

    @Test
    func singleSlotFailureDegradesWhenNotStrict() async throws {
        try await withTempDir("review-degrade-single") { root in
            try writeFile("Sources/A.swift", "let x = 1\n", in: root)
            let docker = OneSlotFailDocker(workspace: root)
            let invocation = OpenCodeInvocation(
                docker: docker,
                image: "gegenlesen/opencode-runner:0.1.0",
                runnerConfig: repoRootFromAgentTests().appendingPathComponent("docker/opencode-runner")
            )
            let job = sampleJob()
            let result = await invocation.run(
                AgentReviewRequest(
                    job: job,
                    workspace: Workspace(root: root),
                    files: [
                        JobFile(jobID: job.id, path: "Sources/A.swift", status: .added, language: .swift),
                    ],
                    rules: [],
                    newWork: true,
                    reviewStrictMode: false
                )
            )
            #expect(result.failed == false)
            #expect(result.reviewDegraded == true)
            #expect(result.reviewDegradedSlot == ReviewerSlot.modelB.rawValue)
            #expect(result.validFileCount == 1)
            #expect(result.findings.count == 1)
            let judgePrompt = try String(
                contentsOf: root.appendingPathComponent(".gegenlesen/prompt-judge.md"),
                encoding: .utf8
            )
            #expect(judgePrompt.contains("Degraded review"))
            #expect(judgePrompt.contains("model_a"))
        }
    }

    @Test
    func rateLimitDoesNotRepeatInvestigation() async throws {
        try await withTempDir("review-degrade-ratelimited") { root in
            try writeFile("Sources/A.swift", "let x = 1\n", in: root)
            let docker = RateLimitedThenValidDocker(workspace: root)
            let invocation = OpenCodeInvocation(
                docker: docker,
                image: "gegenlesen/opencode-runner:0.1.0",
                runnerConfig: repoRootFromAgentTests().appendingPathComponent("docker/opencode-runner")
            )
            let job = sampleJob()
            let result = await invocation.run(
                AgentReviewRequest(
                    job: job,
                    workspace: Workspace(root: root),
                    files: [
                        JobFile(jobID: job.id, path: "Sources/A.swift", status: .added, language: .swift),
                    ],
                    rules: [],
                    newWork: true
                )
            )
            #expect(result.failed == false)
            #expect(result.reviewDegraded)
            #expect(result.findings.isEmpty)
            let (attempts, gap) = await docker.stats()
            #expect(attempts == 1)
            #expect(gap == nil)
            let prompt = try String(
                contentsOf: root.appendingPathComponent(".gegenlesen/prompt-model_a.md"),
                encoding: .utf8
            )
            #expect(!prompt.contains("## Retry"))
        }
    }

    @Test
    func rateLimitedSlotDegradesWithProviderErrorName() async throws {
        try await withTempDir("review-degrade-ratelimited-degrade") { root in
            try writeFile("Sources/A.swift", "let x = 1\n", in: root)
            let docker = RateLimitedSlotBDocker(workspace: root)
            let invocation = OpenCodeInvocation(
                docker: docker,
                image: "gegenlesen/opencode-runner:0.1.0",
                runnerConfig: repoRootFromAgentTests().appendingPathComponent("docker/opencode-runner")
            )
            let job = sampleJob()
            let result = await invocation.run(
                AgentReviewRequest(
                    job: job,
                    workspace: Workspace(root: root),
                    files: [
                        JobFile(jobID: job.id, path: "Sources/A.swift", status: .added, language: .swift),
                    ],
                    rules: [],
                    newWork: true,
                    reviewStrictMode: false
                )
            )
            #expect(result.failed == false)
            #expect(result.reviewDegraded == true)
            #expect(result.reviewDegradedError == ReviewFailureClass.providerRateLimited.rawValue)
            #expect(result.reviewDegradedSlot == ReviewerSlot.modelB.rawValue)
        }
    }

    @Test
    func providerRateLimitClassification() {
        #expect(
            ReviewFailureClass.classify(
                errorMessage: "Error: RetriableError: [resource_exhausted]",
                payloadJSON: nil
            ) == .providerRateLimited
        )
        #expect(
            ReviewFailureClass.classify(
                errorMessage: ReviewFailureClass.providerRateLimited.rawValue,
                payloadJSON: nil
            ) == .providerRateLimited
        )
        #expect(
            ReviewFailureClass.classify(
                errorMessage: "reviewer_no_findings_file",
                payloadJSON: nil
            ) == .noFindingsFile
        )
        #expect(
            ReviewFailureClass.providerRateLimitMarker(in: "some source line with 429 in it") == nil
        )
    }
}

actor RateLimitedThenValidDocker: DockerExecuting {
    let workspace: URL
    var attempts = 0
    var attemptAt: [Date] = []

    init(workspace: URL) {
        self.workspace = workspace
    }

    func stats() -> (attempts: Int, gap: Double?) {
        guard attemptAt.count == 2 else { return (attempts, nil) }
        return (attempts, attemptAt[1].timeIntervalSince(attemptAt[0]))
    }

    func run(_ request: DockerRequest) async throws -> DockerResult {
        let slot = request.name.hasSuffix("-a") ? "a" : "b"
        if slot == "a" {
            attempts += 1
            attemptAt.append(Date())
        }
        let gegenlesen = workspace.appendingPathComponent(".gegenlesen", isDirectory: true)
        try FileManager.default.createDirectory(at: gegenlesen, withIntermediateDirectories: true)
        if slot == "a", attempts == 1 {
            return DockerResult(
                exitCode: 1,
                stdout: Data(),
                stderr: Data("Error: RetriableError: [resource_exhausted]\n".utf8)
            )
        }
        if slot == "a" {
            let finding = """
            {"findings":[{"title":"Rate limited retry","message":"Hard-coded value in source.","severity":"error","file_path":"Sources/A.swift","start_line":1,"end_line":1,"snippet":"let x = 1"}]}
            """
            try finding.write(
                to: gegenlesen.appendingPathComponent("findings-model_a.json"),
                atomically: true,
                encoding: .utf8
            )
        } else {
            try #"{"findings":[]}"#.write(
                to: gegenlesen.appendingPathComponent("findings-model_b.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return DockerResult(exitCode: 0, stdout: Data())
    }

    func kill(containerName: String) async {}
    func removeAll(prefix: String) async {}
}

actor RateLimitedSlotBDocker: DockerExecuting {
    let workspace: URL

    init(workspace: URL) {
        self.workspace = workspace
    }

    func run(_ request: DockerRequest) async throws -> DockerResult {
        let gegenlesen = workspace.appendingPathComponent(".gegenlesen", isDirectory: true)
        try FileManager.default.createDirectory(at: gegenlesen, withIntermediateDirectories: true)
        if request.name.hasSuffix("-a") {
            let finding = """
            {"findings":[{"title":"Slot A","message":"Hard-coded value in source.","severity":"error","file_path":"Sources/A.swift","start_line":1,"end_line":1,"snippet":"let x = 1"}]}
            """
            try finding.write(
                to: gegenlesen.appendingPathComponent("findings-model_a.json"),
                atomically: true,
                encoding: .utf8
            )
            return DockerResult(exitCode: 0, stdout: Data())
        }
        return DockerResult(
            exitCode: 1,
            stdout: Data(),
            stderr: Data("Error: RetriableError: [resource_exhausted]\n".utf8)
        )
    }

    func kill(containerName: String) async {}
    func removeAll(prefix: String) async {}
}

actor RetryFindingsDocker: DockerExecuting {
    let workspace: URL
    var attempts: [String: Int] = [:]

    init(workspace: URL) {
        self.workspace = workspace
    }

    func run(_ request: DockerRequest) async throws -> DockerResult {
        let slot = request.name.hasSuffix("-a") ? "a" : "b"
        attempts[slot, default: 0] += 1
        let gegenlesen = workspace.appendingPathComponent(".gegenlesen", isDirectory: true)
        try FileManager.default.createDirectory(at: gegenlesen, withIntermediateDirectories: true)
        let file = gegenlesen.appendingPathComponent("findings-model_\(slot).json")
        if slot == "a", attempts[slot] == 1 {
            try "not json".write(to: file, atomically: true, encoding: .utf8)
        } else if slot == "a" {
            let finding = """
            {"findings":[{"title":"Retry finding","message":"Hard-coded value in source.","severity":"error","file_path":"Sources/A.swift","start_line":1,"end_line":1,"snippet":"let x = 1"}]}
            """
            try finding.write(to: file, atomically: true, encoding: .utf8)
        } else {
            try Data(#"{"findings":[]}"#.utf8).write(to: file)
        }
        return DockerResult(exitCode: 0, stdout: Data())
    }

    func kill(containerName: String) async {}
    func removeAll(prefix: String) async {}
}

actor OneSlotFailDocker: DockerExecuting {
    let workspace: URL

    init(workspace: URL) {
        self.workspace = workspace
    }

    func run(_ request: DockerRequest) async throws -> DockerResult {
        let gegenlesen = workspace.appendingPathComponent(".gegenlesen", isDirectory: true)
        try FileManager.default.createDirectory(at: gegenlesen, withIntermediateDirectories: true)
        if request.name.hasSuffix("-a") {
            let finding = """
            {"findings":[{"title":"Slot A","message":"Hard-coded value in source.","severity":"error","file_path":"Sources/A.swift","start_line":1,"end_line":1,"snippet":"let x = 1"}]}
            """
            try finding.write(
                to: gegenlesen.appendingPathComponent("findings-model_a.json"),
                atomically: true,
                encoding: .utf8
            )
        } else {
            try "garbage".write(
                to: gegenlesen.appendingPathComponent("findings-model_b.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return DockerResult(exitCode: 0, stdout: Data())
    }

    func kill(containerName: String) async {}
    func removeAll(prefix: String) async {}
}

private actor PartialReviewDocker: DockerExecuting {
    let workspace: URL
    let validJSON: Bool
    var calls = 0

    init(workspace: URL, validJSON: Bool) {
        self.workspace = workspace
        self.validJSON = validJSON
    }

    func run(_ request: DockerRequest) async throws -> DockerResult {
        calls += 1
        let slot = request.name.hasSuffix("-a") ? "a" : "b"
        let output = validJSON
            ? #"{"findings":[{"title":"Partial finding","message":"Needs verification","severity":"warning","file_path":"Sources/A.swift","start_line":1,"end_line":1,"snippet":"let x = 1"}]}"#
            : "unfinished json"
        try writeFile(".gegenlesen/findings-model_\(slot).json", output, in: workspace)
        return DockerResult(exitCode: 124, timedOut: true)
    }

    func kill(containerName: String) async {}
    func removeAll(prefix: String) async {}
}
