import Foundation
import Testing
@testable import GegenlesenCore
@testable import GegenlesenDeterministic

@Suite
struct ScannerEngineTests {
    @Test
    func sandboxHasNetworkAndNoProviderKeys() {
        let request = ScannerEngine.request(
            jobID: JobID("job-1"),
            workspace: URL(fileURLWithPath: "/tmp/ws"),
            image: "gegenlesen/scanner:0.1.0",
            timeout: .seconds(999)
        )
        let args = request.dockerCLIArguments()
        #expect(request.network == "bridge")
        #expect(args.contains("bridge"))
        #expect(!args.contains("none"))
        #expect(request.injectProviderKeys == false)
        #expect(request.env["PATH"] == "/usr/local/bin:/usr/bin:/bin")
        #expect(request.env["ANTHROPIC_API_KEY"] == nil)
        #expect(!args.contains { $0.contains("OPENROUTER_API_KEY") })
        #expect(request.memory == "1g")
        #expect(request.timeout == .seconds(120))
        #expect(request.name == "gegenlesen-scan-job-1")
        #expect(request.binds.first?.readOnly == true)
    }

    @Test
    func parseKeepsGitleaksDropsPlaceholderAndPlanted() throws {
        try withTempDir("scan-jsonl") { root in
            try writeFile("Sources/leak.swift", "let github_token = \"ghp_Kj8dN2pQw9LmX4vB7cR1tYhG3sU6wA0zP4\"\n", in: root)
            try writeFile(
                "evals/cases/no-hardcoded-secrets/head/Sources/Config.swift",
                "static let api_key = \"abcdefghijklmnopqrstuvwxyz\"\n",
                in: root
            )
            try writeFile("Sources/fake.swift", "let api_key = \"abcdefghijklmnopqrstuvwxyz\"\n", in: root)
            let jsonl = """
            {"title":"Secret: github","message":"GitHub PAT","severity":"error","file_path":"Sources/leak.swift","start_line":1,"end_line":1,"snippet":"let github_token = \\"ghp_Kj8dN2pQw9LmX4vB7cR1tYhG3sU6wA0zP4\\"","scanner":"gitleaks","requires_judge":false}
            {"title":"planted","message":"no","severity":"error","file_path":"evals/cases/no-hardcoded-secrets/head/Sources/Config.swift","start_line":1,"end_line":1,"snippet":"static let api_key = \\"abcdefghijklmnopqrstuvwxyz\\"","scanner":"gitleaks"}
            {"title":"fake","message":"no","severity":"error","file_path":"Sources/fake.swift","start_line":1,"end_line":1,"snippet":"let api_key = \\"abcdefghijklmnopqrstuvwxyz\\"","scanner":"gitleaks"}
            {"title":"CVE-1 in left-pad","message":"left-pad@1.0.0 is affected","severity":"error","file_path":"Sources/leak.swift","start_line":1,"end_line":1,"snippet":"let github_token = \\"ghp_Kj8dN2pQw9LmX4vB7cR1tYhG3sU6wA0zP4\\"","scanner":"osv-scanner","requires_judge":false}
            {"title":"custom lint","message":"from plugin","severity":"warning","file_path":"Sources/leak.swift","start_line":1,"end_line":1,"snippet":"let github_token = \\"ghp_Kj8dN2pQw9LmX4vB7cR1tYhG3sU6wA0zP4\\"","scanner":"check-shell"}
            """
            let parsed = ScannerEngine.parseJSONL(
                stdout: Data(jsonl.utf8),
                workspace: Workspace(root: root),
                allowedPaths: [
                    "Sources/leak.swift",
                    "Sources/fake.swift",
                    "evals/cases/no-hardcoded-secrets/head/Sources/Config.swift",
                ]
            )
            let ids = parsed.drafts.compactMap { $0.ruleID?.rawValue }
            #expect(ids.contains("scanner-gitleaks"))
            #expect(ids.contains("scanner-osv-scanner"))
            #expect(ids.contains("scanner-check-shell"))
            #expect(parsed.drafts.filter { $0.ruleID?.rawValue == "scanner-gitleaks" }.count == 1)
            #expect(parsed.drafts.contains { $0.ruleID?.rawValue == "scanner-gitleaks" && $0.requiresJudge == false })
            #expect(parsed.drafts.contains { $0.ruleID?.rawValue == "scanner-osv-scanner" && $0.requiresJudge == false })
            #expect(parsed.drafts.contains { $0.ruleID?.rawValue == "scanner-check-shell" && $0.requiresJudge == true })
        }
    }

    @Test
    func runWiresImageAndParsesStdout() async throws {
        try await withTempDir("scan-run") { root in
            try writeFile("a.swift", "print(1)\n", in: root)
            let jsonl = """
            {"title":"hit","message":"from image","severity":"warning","file_path":"a.swift","start_line":1,"end_line":1,"snippet":"print(1)","scanner":"gitleaks","requires_judge":false}
            """
            let docker = RecordingDocker(result: DockerResult(exitCode: 0, stdout: Data(jsonl.utf8)))
            let result = await ScannerEngine(docker: docker, image: "gegenlesen/scanner:0.1.0").run(
                jobID: JobID("job-scan"),
                files: [JobFile(jobID: JobID("job-scan"), path: "a.swift", status: .modified, language: .swift)],
                workspace: Workspace(root: root),
                timeout: .seconds(30)
            )
            #expect(!result.timedOut)
            #expect(result.drafts.count == 1)
            #expect(result.drafts[0].title == "hit")
            let request = try #require(await docker.requests.first)
            #expect(request.image == "gegenlesen/scanner:0.1.0")
            #expect(request.network == "bridge")
            #expect(request.injectProviderKeys == false)
        }
    }
}
