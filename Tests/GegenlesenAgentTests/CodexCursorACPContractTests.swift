import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct CodexCursorACPContractTests {
    @Test
    func codexSlotUsesACPRunnerInCodexImage() throws {
        let invocation = OpenCodeInvocation(
            docker: NoopDocker(),
            image: "gegenlesen/opencode-runner:0.1.0",
            engineImages: [
                AgentEngineID.codex: "gegenlesen/codex-runner:0.1.0",
            ],
            runnerConfig: URL(fileURLWithPath: "/tmp/runner-config")
        )
        let request = try invocation.acpReviewDockerRequest(
            jobID: JobID("job-codex"),
            slot: .modelB,
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            engine: AgentEngineID.codex,
            model: "gpt-5.6-codex"
        )
        let args = request.dockerCLIArguments()
        #expect(request.image == "gegenlesen/codex-runner:0.1.0")
        #expect(args.contains("acp-runner"))
        #expect(args.contains("codex-acp"))
        #expect(args.contains("/workspace/.gegenlesen/findings-model_b.json"))
        #expect(request.env["NO_BROWSER"] == "1")
        #expect(request.env["INITIAL_AGENT_MODE"] == "agent-full-access")
        #expect(request.env["CODEX_CONFIG"]?.contains("sandbox") == true)
    }

    @Test
    func cursorSlotUsesACPRunnerInCursorImage() throws {
        let invocation = OpenCodeInvocation(
            docker: NoopDocker(),
            image: "gegenlesen/opencode-runner:0.1.0",
            engineImages: [
                AgentEngineID.cursorAgent: "gegenlesen/cursor-runner:0.1.0",
            ],
            runnerConfig: URL(fileURLWithPath: "/tmp/runner-config")
        )
        let request = try invocation.acpReviewDockerRequest(
            jobID: JobID("job-cursor"),
            slot: .modelA,
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            engine: AgentEngineID.cursorAgent,
            model: "composer-2.5"
        )
        let args = request.dockerCLIArguments()
        #expect(request.image == "gegenlesen/cursor-runner:0.1.0")
        #expect(args.contains("acp-runner"))
        #expect(args.contains("agent"))
        #expect(args.contains("acp"))
        #expect(args.contains("/workspace/.gegenlesen/findings-model_a.json"))
    }
}
