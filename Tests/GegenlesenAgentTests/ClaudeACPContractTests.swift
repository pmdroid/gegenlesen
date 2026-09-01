import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct ClaudeACPContractTests {
    @Test
    func claudeSlotUsesACPRunnerInClaudeImage() throws {
        let invocation = OpenCodeInvocation(
            docker: NoopDocker(),
            image: "gegenlesen/opencode-runner:0.1.0",
            engineImages: [
                AgentEngineID.claude: "gegenlesen/claude-runner:0.1.0",
            ],
            runnerConfig: URL(fileURLWithPath: "/tmp/runner-config")
        )
        let request = try invocation.acpReviewDockerRequest(
            jobID: JobID("job-claude"),
            slot: .modelA,
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            engine: AgentEngineID.claude,
            model: "claude-sonnet-4-5"
        )
        let args = request.dockerCLIArguments()
        #expect(request.image == "gegenlesen/claude-runner:0.1.0")
        #expect(args.contains("acp-runner"))
        #expect(args.contains("claude-agent-acp"))
        #expect(args.contains("/workspace/.gegenlesen/findings-model_a.json"))
        #expect(args.contains("/workspace/.gegenlesen/prompt-model_a.md"))
        #expect(request.env["ANTHROPIC_MODEL"] == "claude-sonnet-4-5")
    }

    @Test
    func claudeReviewRunParsesGoldenFindingsFixture() async throws {
        try await withTempDir("claude-acp-contract") { root in
            try writeFile("Sources/A.swift", "let x = 1\n", in: root)
            let finding = """
            {"findings":[{"title":"Leaked secret","message":"Hard-coded API key in source.","severity":"error","file_path":"Sources/A.swift","start_line":1,"end_line":1,"snippet":"let x = 1"}]}
            """
            try writeFile(".gegenlesen/findings-model_a.json", finding, in: root)
            try writeFile(".gegenlesen/findings-model_b.json", #"{"findings":[]}"#, in: root)

            let docker = ClaudeACPFindingsDocker(workspace: root)
            let invocation = OpenCodeInvocation(
                docker: docker,
                image: "gegenlesen/opencode-runner:0.1.0",
                engineImages: [AgentEngineID.claude: "gegenlesen/claude-runner:0.1.0"],
                runnerConfig: repoRootFromAgentTests().appendingPathComponent("docker/opencode-runner")
            )
            var job = sampleJob()
            job.reviewerAEngine = AgentEngineID.claude
            job.reviewerAModelID = "claude-sonnet-4-5"
            job.reviewerBEngine = AgentEngineID.opencode
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
            #expect(result.validFileCount == 2)
            #expect(result.findings.count == 1)
            #expect(result.findings[0].title == "Leaked secret")
            let requests = await docker.requests
            #expect(requests.count == 2)
            #expect(requests[0].image == "gegenlesen/claude-runner:0.1.0")
            #expect(requests[0].argv.contains("acp-runner"))
            #expect(requests[1].argv.contains("opencode"))
        }
    }
}

actor ClaudeACPFindingsDocker: DockerExecuting {
    let workspace: URL
    var requests: [DockerRequest] = []

    init(workspace: URL) {
        self.workspace = workspace
    }

    func run(_ request: DockerRequest) async throws -> DockerResult {
        requests.append(request)
        let gegenlesen = workspace.appendingPathComponent(".gegenlesen", isDirectory: true)
        try FileManager.default.createDirectory(at: gegenlesen, withIntermediateDirectories: true)
        if request.name.hasSuffix("-a") {
            if !FileManager.default.fileExists(atPath: gegenlesen.appendingPathComponent("findings-model_a.json").path) {
                try Data(#"{"findings":[]}"#.utf8)
                    .write(to: gegenlesen.appendingPathComponent("findings-model_a.json"))
            }
        }
        if request.name.hasSuffix("-b") {
            try Data(#"{"findings":[]}"#.utf8)
                .write(to: gegenlesen.appendingPathComponent("findings-model_b.json"))
        }
        return DockerResult(exitCode: 0, stdout: Data())
    }

    func kill(containerName: String) async {}
    func removeAll(prefix: String) async {}
}
