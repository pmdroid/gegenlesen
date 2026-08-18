import Foundation
import Testing
@testable import MeisterCore
@testable import MeisterDeterministic

@Suite
struct CommandCheckerTests {
    @Test
    func sandboxArgvHasNetworkNoneAndNoProviderKeys() {
        let request = CommandChecker.request(
            jobID: JobID("job-1"),
            ruleID: RuleID("lint"),
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            image: "meister/opencode-runner:0.1.0",
            argv: ["rg", "TODO"],
            timeout: .seconds(20)
        )
        let args = request.dockerCLIArguments()
        #expect(args.contains("--network"))
        #expect(args.contains("none"))
        #expect(!args.contains("meister-egress"))
        #expect(request.injectProviderKeys == false)
        #expect(request.passThroughEnv.isEmpty)
        #expect(request.env["HOME"] == "/tmp")
        #expect(request.env["PATH"] == "/usr/bin:/bin")
        #expect(request.env["ANTHROPIC_API_KEY"] == nil)
        #expect(request.env["OPENAI_API_KEY"] == nil)
        #expect(!args.contains { $0.contains("ANTHROPIC_API_KEY") })
        #expect(!args.contains { $0.contains("OPENAI_API_KEY") })
        #expect(request.argv == ["rg", "TODO"])
        #expect(request.name == "meister-cmd-job-1-lint")
        #expect(args.contains("--rm"))
        #expect(args.contains("--read-only"))
        #expect(args.contains("1000:1000"))
        #expect(args.contains("1"))
        #expect(args.contains("512m"))
        #expect(args.contains("64"))
        #expect(args.contains("/tmp:rw,nosuid,nodev,uid=1000,gid=1000,size=64m"))

        let oas = OpenAPIBreakChecker.sandboxRequest(
            jobID: JobID("job-1"),
            ruleID: RuleID("openapi-breaking-changes"),
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            image: "meister/opencode-runner:0.1.0",
            argv: ["/usr/local/bin/oasdiff", "breaking", "--format", "json", "/tmp/a", "/tmp/b"]
        )
        let oasArgs = oas.dockerCLIArguments()
        #expect(oasArgs.contains("--network"))
        #expect(oasArgs.contains("none"))
        #expect(!oasArgs.contains { $0.contains("ANTHROPIC_API_KEY") })
        #expect(oas.injectProviderKeys == false)
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
        }
    }
}
