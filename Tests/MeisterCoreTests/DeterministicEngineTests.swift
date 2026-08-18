import Foundation
import Testing
@testable import MeisterCore
@testable import MeisterDeterministic

@Suite
struct DeterministicEngineTests {
    @Test
    func regexDenyAndSiblingProduceFindings() async throws {
        try await withTempDir("det-engine") { root in
            try writeFile("Sources/App.swift", "let api_key = \"abcdefghijklmnopqrstuvwxyz\"\n", in: root)
            try writeFile("Sources/Eval.js", "eval(userInput)\n", in: root)
            try writeFile("Sources/Widget.swift", "struct Widget {}\n", in: root)
            let workspace = Workspace(root: root)
            let job = JobID("job")
            let files = [
                JobFile(jobID: job, path: "Sources/App.swift", status: .modified, language: .swift),
                JobFile(jobID: job, path: "Sources/Eval.js", status: .modified, language: .javascript),
                JobFile(jobID: job, path: "Sources/Widget.swift", status: .added, language: .swift),
            ]
            let rules = [
                sampleRule(
                    id: "no-hardcoded-secrets",
                    globs: ["**/*", "!**/*.md"],
                    payload: .regex(
                        pattern: #"(?i)(api[_-]?key|secret|token)\s*[:=]\s*['"][A-Za-z0-9_\-]{16,}"#,
                        flags: nil,
                        message: "Possible hardcoded secret."
                    )
                ),
                sampleRule(
                    id: "no-eval",
                    languages: ["javascript"],
                    globs: ["**/*.js"],
                    payload: .denyAPI(symbols: ["eval"], message: "no eval")
                ),
                sampleRule(
                    id: "sibling-test-required",
                    languages: ["swift"],
                    globs: ["Sources/**/*.swift"],
                    payload: .siblingTest(sourceGlob: "Sources/**/*.swift", testTemplate: "{stem}Tests.swift")
                ),
            ]
            let result = await DeterministicEngine().run(
                files: files,
                workspace: workspace,
                rules: rules,
                timeout: .seconds(5)
            )
            #expect(!result.timedOut)
            let ids = Set(result.drafts.compactMap { $0.ruleID?.rawValue })
            #expect(ids.contains("no-hardcoded-secrets"))
            #expect(ids.contains("no-eval"))
            #expect(ids.contains("sibling-test-required"))
            #expect(result.drafts.allSatisfy { $0.phase == .deterministic })
        }
    }

    @Test
    func badRegexSkipsRule() async throws {
        try await withTempDir("det-bad-regex") { root in
            try writeFile("a.swift", "hello\n", in: root)
            let files = [JobFile(jobID: JobID("job"), path: "a.swift", status: .modified, language: .swift)]
            let bad = sampleRule(id: "bad-regex", payload: .regex(pattern: "(", flags: nil, message: "x"))
            let good = sampleRule(
                id: "ok-regex",
                payload: .regex(pattern: "hello", flags: nil, message: "found")
            )
            let result = await DeterministicEngine().run(
                files: files,
                workspace: Workspace(root: root),
                rules: [bad, good],
                timeout: .seconds(5)
            )
            #expect(!result.timedOut)
            #expect(result.drafts.map { $0.ruleID?.rawValue } == ["ok-regex"])
        }
    }

    @Test
    func commandAndMissingOasdiffSkip() async throws {
        try await withTempDir("det-skip") { root in
            try writeFile("openapi.yaml", "openapi: 3.0.0\n", in: root)
            let files = [JobFile(jobID: JobID("job"), path: "openapi.yaml", status: .modified, language: .yaml)]
            let rules = [
                sampleRule(id: "cmd", payload: .command(argv: ["true"], timeoutSec: 5)),
                sampleRule(
                    id: "oas",
                    languages: ["yaml"],
                    payload: .openapiBreak(specGlobs: ["**/*.yaml"], failOn: "breaking", message: "break")
                ),
            ]
            let result = await DeterministicEngine(oasdiffAvailable: false).run(
                files: files,
                workspace: Workspace(root: root),
                rules: rules,
                timeout: .seconds(5)
            )
            #expect(result.drafts.isEmpty)
            #expect(!result.timedOut)
        }
    }

    @Test
    func zeroTimeoutExpiresWithoutHanging() async throws {
        try await withTempDir("det-timeout") { root in
            try writeFile("a.swift", "hello\n", in: root)
            let files = [JobFile(jobID: JobID("job"), path: "a.swift", status: .modified, language: .swift)]
            let rule = sampleRule(id: "ok-regex", payload: .regex(pattern: "hello", flags: nil, message: "found"))
            let result = await DeterministicEngine().run(
                files: files,
                workspace: Workspace(root: root),
                rules: [rule],
                timeout: .zero
            )
            #expect(result.timedOut)
            #expect(result.drafts.isEmpty)
        }
    }

    @Test
    func commandJSONLBecomesDeterministicFindings() async throws {
        try await withTempDir("det-cmd-ok") { root in
            try writeFile("Sources/A.swift", "print(2)\n", in: root)
            let jsonl = """
            {"title":"cmd hit","message":"from sandbox","severity":"warning","file_path":"Sources/A.swift","start_line":1,"end_line":1,"snippet":"print(2)"}
            not-json
            """
            let docker = RecordingDocker(
                result: DockerResult(exitCode: 0, stdout: Data(jsonl.utf8))
            )
            let result = await DeterministicEngine(docker: docker).run(
                files: [JobFile(jobID: JobID("job-cmd"), path: "Sources/A.swift", status: .modified, language: .swift)],
                workspace: Workspace(root: root),
                rules: [sampleRule(id: "cmd", payload: .command(argv: ["rg", "todo"], timeoutSec: 5))],
                timeout: .seconds(5)
            )
            #expect(!result.timedOut)
            #expect(result.drafts.count == 1)
            #expect(result.drafts[0].phase == .deterministic)
            #expect(result.drafts[0].ruleID?.rawValue == "cmd")
            #expect(result.drafts[0].title == "cmd hit")
            #expect(result.drafts[0].requiresJudge)
            #expect(result.drafts[0].evidenceOK == true)
            #expect(result.warnings.contains { $0.message == "command_jsonl_invalid" })

            let requests = await docker.requests
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            let args = request.dockerCLIArguments()
            #expect(args.contains("--network"))
            #expect(args.contains("none"))
            #expect(request.network == "none")
            #expect(request.injectProviderKeys == false)
            #expect(request.passThroughEnv.isEmpty)
            #expect(request.env["ANTHROPIC_API_KEY"] == nil)
            #expect(request.env["OPENAI_API_KEY"] == nil)
            #expect(!args.contains { $0.contains("ANTHROPIC_API_KEY") })
            #expect(!args.contains { $0.contains("OPENAI_API_KEY") })
            #expect(request.argv == ["rg", "todo"])
            #expect(request.name == "meister-cmd-job-cmd-cmd")
            #expect(args.contains("1000:1000"))
            #expect(args.contains("--read-only"))
            #expect(request.binds.first?.readOnly == true)
        }
    }

    @Test
    func plantedPasswdSymlinkIsNotReadByNextChecker() async throws {
        try await withTempDir("det-symlink") { root in
            try writeFile("ok.swift", "let safe = 1\n", in: root)
            let link = root.appendingPathComponent("evil.swift")
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: "/etc/passwd"
            )
            let job = JobID("job-link")
            let files = [
                JobFile(jobID: job, path: "ok.swift", status: .modified, language: .swift),
                JobFile(jobID: job, path: "evil.swift", status: .modified, language: .swift),
            ]
            let rule = sampleRule(
                id: "has-root",
                payload: .regex(pattern: "root", flags: nil, message: "passwd leak")
            )
            let result = await DeterministicEngine().run(
                files: files,
                workspace: Workspace(root: root),
                rules: [rule],
                timeout: .seconds(5)
            )
            #expect(result.drafts.isEmpty)
            #expect(Workspace(root: root).resolveForRead("evil.swift") == nil)
            #expect(Workspace(root: root).readRegularFile("evil.swift") == nil)
            Workspace(root: root).removeEscapingSymlinks()
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == nil)
        }
    }

    @Test
    func intermediateDirectorySymlinkIsNotFollowed() async throws {
        try await withTempDir("det-mid-link") { root in
            let sources = root.appendingPathComponent("Sources")
            try FileManager.default.createSymbolicLink(
                atPath: sources.path,
                withDestinationPath: "/etc"
            )
            let job = JobID("job-mid")
            let files = [
                JobFile(jobID: job, path: "Sources/passwd", status: .modified, language: .other),
            ]
            let rule = sampleRule(
                id: "has-root",
                payload: .regex(pattern: "root", flags: nil, message: "passwd leak")
            )
            let result = await DeterministicEngine().run(
                files: files,
                workspace: Workspace(root: root),
                rules: [rule],
                timeout: .seconds(5)
            )
            #expect(result.drafts.isEmpty)
            #expect(Workspace(root: root).resolveForRead("Sources/passwd") == nil)
            #expect(Workspace(root: root).readRegularFile("Sources/passwd") == nil)
        }
    }

    @Test
    func commandNonzeroExitEmitsNoFindings() async throws {
        try await withTempDir("det-cmd-err") { root in
            try writeFile("Sources/A.swift", "print(2)\n", in: root)
            let docker = RecordingDocker(
                result: DockerResult(
                    exitCode: 1,
                    stderr: Data("ANTHROPIC_API_KEY=sk-ant-secretvalue\nbad\n".utf8)
                )
            )
            let result = await DeterministicEngine(docker: docker).run(
                files: [JobFile(jobID: JobID("job-err"), path: "Sources/A.swift", status: .modified, language: .swift)],
                workspace: Workspace(root: root),
                rules: [sampleRule(id: "cmd", payload: .command(argv: ["false"], timeoutSec: 5))],
                timeout: .seconds(5)
            )
            #expect(!result.timedOut)
            #expect(result.drafts.isEmpty)
            #expect(result.warnings.count == 1)
            #expect(result.warnings[0].message == "command_error")
            let payload = try #require(result.warnings[0].payloadJSON)
            #expect(payload.contains("[REDACTED]"))
            #expect(!payload.contains("sk-ant-secretvalue"))
        }
    }
}