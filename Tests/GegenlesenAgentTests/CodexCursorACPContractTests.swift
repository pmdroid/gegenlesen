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
        #expect(args.contains("--model"))
        #expect(args.contains("composer-2.5"))
        #expect(request.env["CURSOR_MODEL"] == "composer-2.5")
        #expect(request.env["CURSOR_ACP_MODEL"] == "composer-2.5")
        #expect(args.contains("/workspace/.gegenlesen/findings-model_a.json"))
    }

    @Test
    func cursorJudgeUsesACPRunnerInCursorImage() throws {
        let invocation = OpenCodeInvocation(
            docker: NoopDocker(),
            image: "gegenlesen/opencode-runner:0.1.0",
            engineImages: [
                AgentEngineID.cursorAgent: "gegenlesen/cursor-runner:0.1.0",
            ],
            runnerConfig: URL(fileURLWithPath: "/tmp/runner-config"),
            judgeTimeout: .seconds(300)
        )
        let request = try invocation.acpJudgeDockerRequest(
            jobID: JobID("job-cursor-judge"),
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            engine: AgentEngineID.cursorAgent,
            model: "grok-4.6[effort=high,fast=true]"
        )
        let args = request.dockerCLIArguments()
        #expect(request.image == "gegenlesen/cursor-runner:0.1.0")
        #expect(args.contains("acp-runner"))
        #expect(args.contains("agent"))
        #expect(args.contains("acp"))
        #expect(args.contains("--model"))
        #expect(args.contains("grok-4.6[effort=high,fast=true]"))
        #expect(args.contains("/workspace/.gegenlesen/judge.json"))
        #expect(args.contains("/workspace/.gegenlesen/prompt-judge.md"))
        #expect(request.env["CURSOR_ACP_MODEL"] == "grok-4.6[effort=high,fast=true]")
    }

    @Test
    func codexConfigEscapesModelName() {
        let config = ACPEngines.codexConfigJSON(baseModel: #"gpt-5","sandbox":"enabled"#)
        #expect(config.contains(#""model":"gpt-5\",\"sandbox\":\"enabled""#))
        let data = config.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: String]
        #expect(parsed["model"] == #"gpt-5","sandbox":"enabled"#)
        #expect(parsed["sandbox"] == "disabled")
    }

    @Test
    func grokSlotUsesACPRunnerInGrokImage() throws {
        let invocation = OpenCodeInvocation(
            docker: NoopDocker(),
            image: "gegenlesen/opencode-runner:0.1.0",
            engineImages: [
                AgentEngineID.grok: "gegenlesen/grok-runner:0.1.0",
            ],
            runnerConfig: URL(fileURLWithPath: "/tmp/runner-config")
        )
        let request = try invocation.acpReviewDockerRequest(
            jobID: JobID("job-grok"),
            slot: .modelA,
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            engine: AgentEngineID.grok,
            model: "grok-4.6"
        )
        let args = request.dockerCLIArguments()
        #expect(request.image == "gegenlesen/grok-runner:0.1.0")
        #expect(args.contains("acp-runner"))
        #expect(args.contains("agent"))
        #expect(args.contains("stdio"))
        #expect(args.contains("--model"))
        #expect(args.contains("grok-4.6"))
        #expect(args.contains("/workspace/.gegenlesen/findings-model_a.json"))
        #expect(request.env["GROK_MODEL"] == "grok-4.6")
        #expect(request.env["GROK_ACP_MODEL"] == "grok-4.6")
    }

    @Test
    func cursorMinerUsesACPRunnerInCursorImage() throws {
        let invocation = OpenCodeInvocation(
            docker: NoopDocker(),
            image: "gegenlesen/opencode-runner:0.1.0",
            engineImages: [
                AgentEngineID.cursorAgent: "gegenlesen/cursor-runner:0.1.0",
            ],
            runnerConfig: URL(fileURLWithPath: "/tmp/runner-config")
        )
        let request = try invocation.acpMinerDockerRequest(
            jobID: JobID("job-cursor-mine"),
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            engine: AgentEngineID.cursorAgent,
            model: "composer-2.5",
            output: "mine",
            outputPath: "/workspace/.gegenlesen/mined-rules.json"
        )
        let args = request.dockerCLIArguments()
        #expect(request.image == "gegenlesen/cursor-runner:0.1.0")
        #expect(args.contains("acp-runner"))
        #expect(args.contains("agent"))
        #expect(args.contains("acp"))
        #expect(args.contains("mine"))
        #expect(args.contains("/workspace/.gegenlesen/mined-rules.json"))
        #expect(args.contains("/workspace/.gegenlesen/prompt.md"))
        #expect(request.env["CURSOR_ACP_MODEL"] == "composer-2.5")
    }

    @Test
    func grokSuggestionJudgeUsesACPRunner() throws {
        let invocation = OpenCodeInvocation(
            docker: NoopDocker(),
            image: "gegenlesen/opencode-runner:0.1.0",
            engineImages: [
                AgentEngineID.grok: "gegenlesen/grok-runner:0.1.0",
            ],
            runnerConfig: URL(fileURLWithPath: "/tmp/runner-config"),
            judgeTimeout: .seconds(300)
        )
        let request = try invocation.acpSuggestionJudgeDockerRequest(
            jobID: JobID("job-grok-sug"),
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            engine: AgentEngineID.grok,
            model: "grok-4.6"
        )
        let args = request.dockerCLIArguments()
        #expect(request.image == "gegenlesen/grok-runner:0.1.0")
        #expect(args.contains("acp-runner"))
        #expect(args.contains("suggestion_judge"))
        #expect(args.contains("/workspace/.gegenlesen/suggestion-judge.json"))
        #expect(args.contains("/workspace/.gegenlesen/prompt-suggestion-judge.md"))
        #expect(request.env["GROK_ACP_MODEL"] == "grok-4.6")
    }
}
