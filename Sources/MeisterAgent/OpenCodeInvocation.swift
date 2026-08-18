import Foundation
import MeisterCore

public struct OpenCodeInvocation: ReviewerRunning, MinerRunning, Sendable {
    public var docker: any DockerExecuting
    public var http: any OpenCodeHTTPClienting
    public var image: String
    public var runnerConfig: URL
    public var cpus: String
    public var memory: String
    public var agentTimeout: Duration
    public var healthTimeout: Duration
    public var providerEnv: [String: String]
    public var schemasDirectory: URL?
    public var transcriptWriter: (@Sendable (JobID, Data) -> Void)?

    public init(
        docker: any DockerExecuting,
        http: any OpenCodeHTTPClienting = OpenCodeHTTPClient(),
        image: String,
        runnerConfig: URL,
        cpus: String = ProcessInfo.processInfo.environment["MEISTER_DOCKER_CPUS"] ?? "2",
        memory: String = ProcessInfo.processInfo.environment["MEISTER_DOCKER_MEMORY"] ?? "4g",
        agentTimeout: Duration = .seconds(900),
        healthTimeout: Duration = .seconds(30),
        providerEnv: [String: String] = [:],
        schemasDirectory: URL? = nil,
        transcriptWriter: (@Sendable (JobID, Data) -> Void)? = nil
    ) {
        self.docker = docker
        self.http = http
        self.image = image
        self.runnerConfig = runnerConfig
        self.cpus = cpus
        self.memory = memory
        self.agentTimeout = agentTimeout
        self.healthTimeout = healthTimeout
        self.providerEnv = providerEnv
        self.schemasDirectory = schemasDirectory
        self.transcriptWriter = transcriptWriter
    }

    public func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        let jobID = request.job.id
        let nameA = Self.containerName(jobID: jobID, slot: .modelA)
        let nameB = Self.containerName(jobID: jobID, slot: .modelB)
        let judgeName = "meister-judge-\(jobID.rawValue)"
        do {
            if let runner = docker as? DockerRunner {
                try runner.ensureEgressNetwork()
            }
            try Quarantine.run(workspace: request.workspace)
            try DockerRunner.chownWorkspace(request.workspace.root)
            try PromptRenderer(schemasDirectory: schemasDirectory).write(
                workspace: request.workspace,
                job: request.job,
                files: request.files,
                rules: request.rules
            )
        } catch {
            return AgentReviewResult(
                findings: [],
                validFileCount: 0,
                failed: request.newWork,
                errorMessage: String(describing: error),
                containerNameA: nameA,
                containerNameB: nameB,
                containerName: judgeName
            )
        }

        let known = Set(request.rules.map(\.id))
        async let slotA = runSlot(
            request,
            slot: .modelA,
            model: request.job.reviewerAModelID,
            known: known
        )
        async let slotB = runSlot(
            request,
            slot: .modelB,
            model: request.job.reviewerBModelID,
            known: known
        )
        let (resultA, resultB) = await (slotA, slotB)

        let findings = resultA.findings + resultB.findings
        let valid = (resultA.valid ? 1 : 0) + (resultB.valid ? 1 : 0)
        let failed = request.newWork && valid == 0
        persistTranscripts(jobID: jobID, chunks: [resultA.transcript, resultB.transcript])
        persistAgentCopies(workspace: request.workspace, jobID: jobID)
        return AgentReviewResult(
            findings: findings,
            validFileCount: valid,
            failed: failed,
            errorMessage: failed ? "reviewer_no_findings_file" : nil,
            containerNameA: nameA,
            containerNameB: nameB,
            containerName: judgeName
        )
    }

    public static func containerName(jobID: JobID, slot: ReviewerSlot) -> String {
        ReviewContainers.slot(jobID, slot)
    }

    public func reviewDockerRequest(
        jobID: JobID,
        slot: ReviewerSlot,
        workspace: URL,
        hostPort: Int,
        password: String,
        model: String,
        fallbackRun: Bool
    ) throws -> DockerRequest {
        let policy = try OpenCodeConfig.policyJSON(model: model, defaultAgent: "reviewer")
        let permission = try OpenCodeConfig.permissionJSON()
        var env: [String: String] = [
            "HOME": "/home/meister",
            "OPENCODE_DISABLE_AUTOUPDATE": "true",
            "OPENCODE_AUTO_SHARE": "false",
            "OPENCODE_DISABLE_DEFAULT_PLUGINS": "true",
            "OPENCODE_DISABLE_CLAUDE_CODE": "true",
            "OPENCODE_CONFIG": "/home/meister/.config/opencode/opencode.json",
            "OPENCODE_CONFIG_CONTENT": policy,
            "OPENCODE_PERMISSION": permission,
            "OPENCODE_SERVER_PASSWORD": password,
            "OPENCODE_SERVER_USERNAME": "opencode",
        ]
        for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"] {
            if let value = providerEnv[key], !value.isEmpty {
                env[key] = value
            }
        }
        let argv: [String]
        if fallbackRun {
            argv = [
                "opencode", "run",
                "--agent", "reviewer",
                "--model", model,
                "--auto",
                "--format", "json",
            ]
        } else {
            argv = ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "4096"]
        }
        return DockerRequest(
            name: Self.containerName(jobID: jobID, slot: slot),
            image: image,
            argv: argv,
            env: env,
            network: "meister-egress",
            workdir: "/workspace",
            publishLoopback: fallbackRun ? nil : (hostPort, 4096),
            user: "1000:1000",
            readOnly: true,
            tmpfs: [
                "/tmp:rw,nosuid,nodev,uid=1000,gid=1000,size=512m",
                "/home/meister/.local:rw,nosuid,nodev,uid=1000,gid=1000,size=256m",
                "/home/meister/.config/opencode-state:rw,nosuid,nodev,uid=1000,gid=1000,size=64m",
            ],
            binds: [
                .init(source: workspace.path, dest: "/workspace", readOnly: false),
                .init(source: runnerConfig.path, dest: "/home/meister/.config/opencode", readOnly: true),
            ],
            cpus: cpus,
            memory: memory,
            pidsLimit: 256,
            capDropAll: true,
            noNewPrivileges: true,
            ulimitNproc: "256:256",
            ulimitNofile: "1024:1024",
            timeout: agentTimeout,
            injectProviderKeys: true,
            remove: true,
            passThroughEnv: [
                "ANTHROPIC_API_KEY",
                "OPENAI_API_KEY",
                "OPENROUTER_API_KEY",
                "OPENCODE_SERVER_PASSWORD",
            ]
        )
    }

    public func minerDockerRequest(
        jobID: JobID,
        workspace: URL,
        hostPort: Int,
        password: String,
        model: String,
        fallbackRun: Bool
    ) throws -> DockerRequest {
        let policy = try OpenCodeConfig.policyJSON(model: model, defaultAgent: "miner")
        let permission = try OpenCodeConfig.permissionJSON()
        var env: [String: String] = [
            "HOME": "/home/meister",
            "OPENCODE_DISABLE_AUTOUPDATE": "true",
            "OPENCODE_AUTO_SHARE": "false",
            "OPENCODE_DISABLE_DEFAULT_PLUGINS": "true",
            "OPENCODE_DISABLE_CLAUDE_CODE": "true",
            "OPENCODE_CONFIG": "/home/meister/.config/opencode/opencode.json",
            "OPENCODE_CONFIG_CONTENT": policy,
            "OPENCODE_PERMISSION": permission,
            "OPENCODE_SERVER_PASSWORD": password,
            "OPENCODE_SERVER_USERNAME": "opencode",
        ]
        for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"] {
            if let value = providerEnv[key], !value.isEmpty {
                env[key] = value
            }
        }
        let argv: [String]
        if fallbackRun {
            argv = [
                "opencode", "run",
                "--agent", "miner",
                "--model", model,
                "--auto",
                "--format", "json",
            ]
        } else {
            argv = ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "4096"]
        }
        return DockerRequest(
            name: ReviewContainers.miner(jobID),
            image: image,
            argv: argv,
            env: env,
            network: "meister-egress",
            workdir: "/workspace",
            publishLoopback: fallbackRun ? nil : (hostPort, 4096),
            user: "1000:1000",
            readOnly: true,
            tmpfs: [
                "/tmp:rw,nosuid,nodev,uid=1000,gid=1000,size=512m",
                "/home/meister/.local:rw,nosuid,nodev,uid=1000,gid=1000,size=256m",
                "/home/meister/.config/opencode-state:rw,nosuid,nodev,uid=1000,gid=1000,size=64m",
            ],
            binds: [
                .init(source: workspace.path, dest: "/workspace", readOnly: false),
                .init(source: runnerConfig.path, dest: "/home/meister/.config/opencode", readOnly: true),
            ],
            cpus: cpus,
            memory: memory,
            pidsLimit: 256,
            capDropAll: true,
            noNewPrivileges: true,
            ulimitNproc: "256:256",
            ulimitNofile: "1024:1024",
            timeout: agentTimeout,
            injectProviderKeys: true,
            remove: true,
            passThroughEnv: [
                "ANTHROPIC_API_KEY",
                "OPENAI_API_KEY",
                "OPENROUTER_API_KEY",
                "OPENCODE_SERVER_PASSWORD",
            ]
        )
    }

    public func runMiner(
        jobID: JobID,
        workspace: Workspace,
        model: String,
        isCancelled: (@Sendable () async -> Bool)? = nil
    ) async -> MinerRunResult {
        let name = ReviewContainers.miner(jobID)
        do {
            if let runner = docker as? DockerRunner {
                try runner.ensureEgressNetwork()
            }
            try Quarantine.run(workspace: workspace)
            try DockerRunner.chownWorkspace(workspace.root)
        } catch {
            return MinerRunResult(containerName: name, failed: true, errorMessage: String(describing: error))
        }

        if await isCancelled?() == true {
            return MinerRunResult(containerName: name, failed: true, errorMessage: "cancelled")
        }

        let password = Self.randomPassword()
        let lease: LoopbackPortLease
        do {
            lease = try DockerRunner.allocateLoopbackPort()
        } catch {
            return MinerRunResult(containerName: name, failed: true, errorMessage: String(describing: error))
        }
        let serve: DockerRequest
        do {
            serve = try minerDockerRequest(
                jobID: jobID,
                workspace: workspace.root,
                hostPort: lease.port,
                password: password,
                model: model,
                fallbackRun: false
            )
        } catch {
            lease.release()
            return MinerRunResult(containerName: name, failed: true, errorMessage: String(describing: error))
        }
        let port = lease.port
        let serveTask = Task {
            lease.release()
            return try await docker.run(serve)
        }
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let healthy = await http.waitUntilHealthy(baseURL: baseURL, password: password, timeout: healthTimeout)
        var transcript = Data()
        if await isCancelled?() == true {
            await docker.kill(containerName: serve.name)
            _ = try? await serveTask.value
            return MinerRunResult(containerName: name, failed: true, errorMessage: "cancelled")
        }
        if healthy {
            do {
                let session = try await http.createSession(
                    baseURL: baseURL,
                    password: password,
                    title: "meister-mine-\(jobID.rawValue)"
                )
                let promptURL = workspace.root.appendingPathComponent(".meister/prompt.md")
                let prompt = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? ""
                try await http.sendReview(
                    baseURL: baseURL,
                    password: password,
                    sessionID: session,
                    agent: "miner",
                    model: model,
                    prompt: prompt,
                    filePaths: ["/workspace/.meister/prompt.md"],
                    timeout: agentTimeout
                )
                await http.abort(baseURL: baseURL, password: password, sessionID: session)
            } catch {
                transcript.append(contentsOf: Data("http_error\n".utf8))
            }
            await docker.kill(containerName: serve.name)
            if let result = try? await serveTask.value {
                transcript.append(SecretRedactor().redact(result.stdout))
                transcript.append(SecretRedactor().redact(result.stderr))
            }
        } else {
            await docker.kill(containerName: serve.name)
            _ = try? await serveTask.value
            let fallback: DockerRequest
            do {
                fallback = try minerDockerRequest(
                    jobID: jobID,
                    workspace: workspace.root,
                    hostPort: port,
                    password: password,
                    model: model,
                    fallbackRun: true
                )
            } catch {
                return MinerRunResult(containerName: name, failed: true, errorMessage: String(describing: error))
            }
            if let result = try? await docker.run(fallback) {
                transcript.append(SecretRedactor().redact(result.stdout))
                transcript.append(SecretRedactor().redact(result.stderr))
            }
        }

        persistTranscripts(jobID: jobID, chunks: [transcript])
        return MinerRunResult(containerName: name, failed: false)
    }

    private struct SlotOutcome: Sendable {
        var findings: [Finding]
        var valid: Bool
        var transcript: Data
    }

    private func runSlot(
        _ request: AgentReviewRequest,
        slot: ReviewerSlot,
        model: String,
        known: Set<RuleID>
    ) async -> SlotOutcome {
        if await request.isCancelled?() == true {
            return SlotOutcome(findings: [], valid: false, transcript: Data())
        }
        let password = Self.randomPassword()
        let lease: LoopbackPortLease
        do {
            lease = try DockerRunner.allocateLoopbackPort()
        } catch {
            return SlotOutcome(findings: [], valid: false, transcript: Data())
        }
        let serve: DockerRequest
        do {
            serve = try reviewDockerRequest(
                jobID: request.job.id,
                slot: slot,
                workspace: request.workspace.root,
                hostPort: lease.port,
                password: password,
                model: model,
                fallbackRun: false
            )
        } catch {
            lease.release()
            return SlotOutcome(findings: [], valid: false, transcript: Data())
        }
        let port = lease.port
        let serveTask = Task {
            lease.release()
            return try await docker.run(serve)
        }
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let healthy = await http.waitUntilHealthy(baseURL: baseURL, password: password, timeout: healthTimeout)
        var transcript = Data()
        if await request.isCancelled?() == true {
            await docker.kill(containerName: serve.name)
            _ = try? await serveTask.value
            return SlotOutcome(findings: [], valid: false, transcript: Data())
        }
        if healthy {
            do {
                let session = try await http.createSession(
                    baseURL: baseURL,
                    password: password,
                    title: "meister-review-\(request.job.id.rawValue)"
                )
                let promptURL = request.workspace.root
                    .appendingPathComponent(".meister/prompt-\(slot.rawValue).md")
                let prompt = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? ""
                try await http.sendReview(
                    baseURL: baseURL,
                    password: password,
                    sessionID: session,
                    agent: "reviewer",
                    model: model,
                    prompt: prompt,
                    filePaths: [
                        "/workspace/.meister/rules.json",
                        "/workspace/.meister/diff.patch",
                    ],
                    timeout: agentTimeout
                )
                await http.abort(baseURL: baseURL, password: password, sessionID: session)
            } catch {
                transcript.append(contentsOf: Data("http_error\n".utf8))
            }
            await docker.kill(containerName: serve.name)
            if let result = try? await serveTask.value {
                transcript.append(SecretRedactor().redact(result.stdout))
                transcript.append(SecretRedactor().redact(result.stderr))
            }
        } else {
            await docker.kill(containerName: serve.name)
            _ = try? await serveTask.value
            let fallback: DockerRequest
            do {
                fallback = try reviewDockerRequest(
                    jobID: request.job.id,
                    slot: slot,
                    workspace: request.workspace.root,
                    hostPort: port,
                    password: password,
                    model: model,
                    fallbackRun: true
                )
            } catch {
                return SlotOutcome(findings: [], valid: false, transcript: transcript)
            }
            if let result = try? await docker.run(fallback) {
                transcript.append(SecretRedactor().redact(result.stdout))
                transcript.append(SecretRedactor().redact(result.stderr))
            }
        }

        let url = FindingsParser.findingsURL(workspace: request.workspace, slot: slot)
        let shared = request.workspace.root.appendingPathComponent(".meister/findings.json")
        let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: shared))
        guard let data else {
            return SlotOutcome(findings: [], valid: false, transcript: transcript)
        }
        do {
            let parsed = try FindingsParser.parse(
                file: data,
                workspace: request.workspace,
                knownRuleIDs: known,
                jobID: request.job.id,
                slot: slot
            )
            return SlotOutcome(findings: parsed.findings, valid: true, transcript: transcript)
        } catch {
            return SlotOutcome(findings: [], valid: false, transcript: transcript)
        }
    }

    private func persistTranscripts(jobID: JobID, chunks: [Data]) {
        var combined = Data()
        for chunk in chunks {
            combined.append(SecretRedactor().redact(chunk))
        }
        transcriptWriter?(jobID, combined)
    }

    private func persistAgentCopies(workspace: Workspace, jobID: JobID) {
        let fm = FileManager.default
        let dest = workspace.root.appendingPathComponent(".meister/agent-findings.json")
        for name in ["findings-model_a.json", "findings-model_b.json", "findings.json"] {
            let source = workspace.root.appendingPathComponent(".meister/\(name)")
            if fm.fileExists(atPath: source.path) {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: source, to: dest)
                return
            }
        }
    }

    private static func randomPassword() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }
}
