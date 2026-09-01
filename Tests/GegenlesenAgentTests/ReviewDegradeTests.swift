import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct ReviewDegradeTests {
    @Test
    func retryAfterGarbageThenAcceptsValidJSON() async throws {
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
            #expect(result.findings.count == 1)
            #expect(result.findings[0].title == "Retry finding")
            let attempts = await docker.attempts
            #expect(attempts["a"] == 2)
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
