import Foundation
import Testing
@testable import GegenlesenCore
@testable import GegenlesenDeterministic

@Suite
struct CommandCheckerTests {
    @Test
    func sandboxArgvHasNetworkNoneAndNoProviderKeys() {
        let request = CommandChecker.request(
            jobID: JobID("job-1"),
            ruleID: RuleID("lint"),
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            image: "gegenlesen/opencode-runner:0.1.0",
            argv: ["rg", "TODO"],
            timeout: .seconds(20)
        )
        let args = request.dockerCLIArguments()
        #expect(args.contains("--network"))
        #expect(args.contains("none"))
        #expect(!args.contains("gegenlesen-egress"))
        #expect(request.injectProviderKeys == false)
        #expect(request.passThroughEnv.isEmpty)
        #expect(request.env["HOME"] == "/tmp")
        #expect(request.env["PATH"] == "/usr/bin:/bin")
        #expect(request.env["ANTHROPIC_API_KEY"] == nil)
        #expect(request.env["OPENAI_API_KEY"] == nil)
        #expect(!args.contains { $0.contains("ANTHROPIC_API_KEY") })
        #expect(!args.contains { $0.contains("OPENAI_API_KEY") })
        #expect(request.argv == ["rg", "TODO"])
        #expect(request.name == "gegenlesen-cmd-job-1-lint")
        #expect(args.contains("--rm"))
        #expect(args.contains("--read-only"))
        #expect(args.contains("1000:1000"))
        #expect(args.contains("1"))
        #expect(args.contains("512m"))
        #expect(args.contains("64"))
        #expect(args.contains("/tmp:rw,nosuid,nodev,noexec,uid=1000,gid=1000,size=64m"))
        #expect(request.binds.first?.readOnly == true)
        #expect(request.timeout == .seconds(20))

        let oas = OpenAPIBreakChecker.sandboxRequest(
            jobID: JobID("job-1"),
            ruleID: RuleID("openapi-breaking-changes"),
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            image: "gegenlesen/opencode-runner:0.1.0",
            argv: ["/usr/local/bin/oasdiff", "breaking", "--format", "json", "/tmp/a", "/tmp/b"],
            timeout: .seconds(999)
        )
        let oasArgs = oas.dockerCLIArguments()
        #expect(oasArgs.contains("--network"))
        #expect(oasArgs.contains("none"))
        #expect(!oasArgs.contains { $0.contains("ANTHROPIC_API_KEY") })
        #expect(oas.injectProviderKeys == false)
        #expect(oas.timeout == .seconds(20))
        #expect(oas.binds.first?.readOnly == true)
    }

    @Test
    func runCapsRuleTimeoutAt20s() async throws {
        try await withTempDir("cmd-timeout-cap") { root in
            try writeFile("a.swift", "hello\n", in: root)
            let docker = RecordingDocker(result: DockerResult(exitCode: 0, stdout: Data()))
            let outcome = await CommandChecker(
                docker: docker,
                image: "gegenlesen/opencode-runner:0.1.0"
            ).run(
                jobID: JobID("job-1"),
                workspace: Workspace(root: root),
                rule: sampleRule(id: "lint", payload: .command(argv: ["true"], timeoutSec: 999)),
                timeout: .seconds(60)
            )
            #expect(!outcome.timedOut)
            let request = try #require(await docker.requests.first)
            #expect(request.timeout == .seconds(20))
            #expect(request.binds.first?.readOnly == true)
        }
    }

    @Test
    func parseJSONLSkipsInvalidLines() throws {
        try withTempDir("cmd-jsonl") { root in
            try writeFile("a.swift", "hello\n", in: root)
            let stdout = Data(
                """
                {"title":"ok","message":"hit","severity":"error","file_path":"a.swift","start_line":1,"end_line":1,"snippet":"hello"}
                {not json}
                {"title":"bad path","message":"hit","severity":"error","file_path":"../etc/passwd","start_line":1,"end_line":1,"snippet":"x"}
                """.utf8
            )
            let parsed = CommandChecker.parseJSONL(
                stdout: stdout,
                workspace: Workspace(root: root),
                rule: sampleRule(id: "cmd", payload: .command(argv: ["true"], timeoutSec: 5))
            )
            #expect(parsed.drafts.count == 1)
            #expect(parsed.invalid == 2)
            #expect(parsed.drafts[0].phase == .deterministic)
            #expect(parsed.drafts[0].filePath == "a.swift")
            #expect(parsed.drafts[0].requiresJudge)
            #expect(parsed.drafts[0].rationale == nil)
        }
    }

    @Test
    func parseJSONLBoundsOptionalFieldsAndRedactsPEM() throws {
        try withTempDir("cmd-bounds") { root in
            try writeFile("a.swift", "hello\n", in: root)
            let long = String(repeating: "x", count: 5000)
            let stdout = Data(
                """
                {"title":"ok","message":"hit","severity":"error","file_path":"a.swift","start_line":1,"end_line":1,"snippet":"hello","rationale":"\(long)","suggested_patch":"\(long)","confidence":1.5}
                """.utf8
            )
            let parsed = CommandChecker.parseJSONL(
                stdout: stdout,
                workspace: Workspace(root: root),
                rule: sampleRule(id: "cmd", payload: .command(argv: ["true"], timeoutSec: 5))
            )
            #expect(parsed.drafts.count == 1)
            #expect(parsed.drafts[0].rationale?.utf8.count == 4000)
            #expect(parsed.drafts[0].suggestedPatch?.utf8.count == 5000)
            #expect(parsed.drafts[0].confidence == nil)
            #expect(parsed.drafts[0].requiresJudge)

            let pem = """
            -----BEGIN RSA PRIVATE KEY-----
            MIIEowIBAAKCAQEA0
            -----END RSA PRIVATE KEY-----
            """
            let warning = CommandChecker.payloadJSON([
                "rule_id": "cmd",
                "stderr": CommandChecker.redact("oops \(pem) ANTHROPIC_API_KEY=sk-ant-secretvalue"),
            ])
            let payload = try #require(warning)
            #expect(payload.contains("[REDACTED]"))
            #expect(!payload.contains("MIIEowIBAAKCAQEA0"))
            #expect(!payload.contains("sk-ant-secretvalue"))
            #expect((try? JSONSerialization.jsonObject(with: Data(payload.utf8))) != nil)
        }
    }
}
