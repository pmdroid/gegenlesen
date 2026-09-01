import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct AgentEngineTests {
    @Test
    func registryResolvesOpenCodeByID() throws {
        let engine = try AgentEngineRegistry.default.engine(id: "opencode")
        #expect(engine.id == OpenCodeEngine.engineID)
        #expect(AgentEngineRegistry.default.engineIDs == ["claude", "codex", "cursor-agent", "grok", "opencode"])
        #expect(AgentEngineRegistry.defaultEngineID == "opencode")
    }

    @Test
    func registryResolvesClaudeByID() throws {
        let engine = try AgentEngineRegistry.default.engine(id: AgentEngineID.claude)
        #expect(engine.id == ClaudeEngine.engineID)
    }

    @Test
    func registryRejectsUnknownEngineID() {
        #expect(throws: AgentEngineError.unknownEngine("nonexistent")) {
            _ = try AgentEngineRegistry.default.engine(id: "nonexistent")
        }
    }

    @Test
    func sandboxBuilderPinsHardeningFlags() {
        let request = AgentSandbox.dockerRequest(
            name: "gegenlesen-test",
            payload: AgentContainerPayload(
                image: "img",
                argv: ["true"],
                env: ["HOME": "/root", "ENGINE_FLAG": "1"],
                tmpfs: ["/scratch:rw,nosuid,nodev,uid=1000,gid=1000,size=16m"],
                binds: [.init(source: "/seed", dest: "/opt/seed", readOnly: true)]
            ),
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            providerEnv: [:],
            cpus: "2",
            memory: "4g",
            timeout: .seconds(60)
        )
        #expect(request.readOnly)
        #expect(request.capDropAll)
        #expect(request.noNewPrivileges)
        #expect(request.pidsLimit == 256)
        #expect(request.user == "1000:1000")
        #expect(request.network == "gegenlesen-egress")
        #expect(request.ulimitNproc == "256:256")
        #expect(request.ulimitNofile == "1024:1024")
        #expect(request.env["HOME"] == "/home/gegenlesen")
        #expect(request.env["ENGINE_FLAG"] == "1")
        #expect(request.tmpfs.first == "/tmp:rw,nosuid,nodev,uid=1000,gid=1000,size=512m")
        #expect(request.tmpfs.contains("/scratch:rw,nosuid,nodev,uid=1000,gid=1000,size=16m"))
        #expect(request.binds.first == DockerRequest.Bind(source: "/tmp/ws", dest: "/workspace", readOnly: false))
        #expect(request.binds.contains(DockerRequest.Bind(source: "/seed", dest: "/opt/seed", readOnly: true)))
    }

    @Test
    func engineInvocationMatchesDirectConstruction() throws {
        let engine = try AgentEngineRegistry.default.engine(id: AgentEngineRegistry.defaultEngineID)
        let invocation = try #require(engine.makeInvocation(AgentEngineConfiguration(
            docker: NoopDocker(),
            image: "gegenlesen/opencode-runner:0.1.0",
            runnerConfig: URL(fileURLWithPath: "/tmp/runner-config")
        )) as? OpenCodeInvocation)
        let direct = OpenCodeInvocation(
            docker: NoopDocker(),
            image: "gegenlesen/opencode-runner:0.1.0",
            runnerConfig: URL(fileURLWithPath: "/tmp/runner-config")
        )
        let fromEngine = try invocation.reviewDockerRequest(
            jobID: JobID("job-1"),
            slot: .modelA,
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            model: "anthropic/claude-sonnet-4-5"
        )
        let expected = try direct.reviewDockerRequest(
            jobID: JobID("job-1"),
            slot: .modelA,
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            model: "anthropic/claude-sonnet-4-5"
        )
        #expect(fromEngine.dockerCLIArguments() == expected.dockerCLIArguments())
    }
}
