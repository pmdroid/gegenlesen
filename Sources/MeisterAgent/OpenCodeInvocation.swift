import Foundation
import MeisterCore

public struct OpenCodeInvocation: ReviewerRunning, MinerRunning, JudgeRunning, SuggestionJudging, Sendable {
    public var docker: any DockerExecuting
    public var image: String
    public var runnerConfig: URL
    public var cpus: String
    public var memory: String
    public var agentTimeout: Duration
    public var judgeTimeout: Duration
    public var providerEnv: [String: String]
    public var schemasDirectory: URL?
    public var transcriptWriter: (@Sendable (JobID, Data) -> Void)?

    public init(
        docker: any DockerExecuting,
        image: String,
        runnerConfig: URL,
        cpus: String = ProcessInfo.processInfo.environment["MEISTER_DOCKER_CPUS"] ?? "2",
        memory: String = ProcessInfo.processInfo.environment["MEISTER_DOCKER_MEMORY"] ?? "4g",
        agentTimeout: Duration = .seconds(900),
        judgeTimeout: Duration = .seconds(300),
        providerEnv: [String: String] = [:],
        schemasDirectory: URL? = nil,
        transcriptWriter: (@Sendable (JobID, Data) -> Void)? = nil
    ) {
        self.docker = docker
        self.image = image
        self.runnerConfig = runnerConfig
        self.cpus = cpus
        self.memory = memory
        self.agentTimeout = agentTimeout
        self.judgeTimeout = judgeTimeout
        self.providerEnv = providerEnv
        self.schemasDirectory = schemasDirectory
        self.transcriptWriter = transcriptWriter
    }

    /// Writable spots on a `--read-only` root. OpenCode writes `~/.cache/opencode/version`
    /// and `~/.config/opencode/package.json` (`opencode run`).
    static let configSeed = "/opt/meister/opencode"
    static let homeTmpfs = [
        "/tmp:rw,nosuid,nodev,uid=1000,gid=1000,size=512m",
        "/home/meister/.local:rw,nosuid,nodev,uid=1000,gid=1000,size=256m",
        "/home/meister/.cache:rw,nosuid,nodev,uid=1000,gid=1000,size=64m",
        "/home/meister/.config/opencode:rw,nosuid,nodev,uid=1000,gid=1000,size=64m",
        "/home/meister/.config/opencode-state:rw,nosuid,nodev,uid=1000,gid=1000,size=64m",
    ]

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
            let diffURL = request.workspace.root.appendingPathComponent(".meister/diff.patch")
            let diffPatch = try? Data(contentsOf: diffURL)
            try PromptRenderer(schemasDirectory: schemasDirectory).write(
                workspace: request.workspace,
                job: request.job,
                files: request.files,
                rules: request.rules,
                parentFindings: request.parentFindings,
                diffPatch: diffPatch
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

    /// Attach only files that exist. Job learn stages `job/` + findings; corpus mines do not.
    public static func minerFilePaths(workspace: Workspace) -> [String] {
        let candidates = [
            ".meister/prompt.md",
            ".meister/architecture-draft.md",
            ".meister/findings.json",
            "job/findings.json",
            "job/feedback.json",
            "job/change.patch",
        ]
        return candidates.compactMap { relative in
            let url = workspace.root.appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return "/workspace/" + relative
        }
    }

    static func reviewFilePaths(incremental: Bool) -> [String] {
        var paths = [
            "/workspace/.meister/rules.json",
            "/workspace/.meister/diff.patch",
        ]
        if incremental {
            paths.append("/workspace/.meister/parent-findings.json")
        }
        return paths
    }

    public func reviewDockerRequest(
        jobID: JobID,
        slot: ReviewerSlot,
        workspace: URL,
        model: String,
        incremental: Bool = false
    ) throws -> DockerRequest {
        try isolatedDockerRequest(
            name: Self.containerName(jobID: jobID, slot: slot),
            workspace: workspace,
            model: model,
            defaultAgent: "reviewer",
            timeout: agentTimeout,
            promptFile: "/workspace/.meister/prompt-\(slot.rawValue).md",
            extraFiles: Self.reviewFilePaths(incremental: incremental),
            message: "Review the change and write findings as instructed."
        )
    }

    public func judgeDockerRequest(
        jobID: JobID,
        workspace: URL,
        model: String
    ) throws -> DockerRequest {
        try isolatedDockerRequest(
            name: ReviewContainers.judge(jobID),
            workspace: workspace,
            model: model,
            defaultAgent: "judge",
            timeout: judgeTimeout,
            promptFile: "/workspace/.meister/prompt-judge.md",
            extraFiles: ["/workspace/.meister/judge-input.json"],
            message: "Judge the candidates as instructed."
        )
    }

    public func suggestionJudgeDockerRequest(
        jobID: JobID,
        workspace: URL,
        model: String
    ) throws -> DockerRequest {
        try isolatedDockerRequest(
            name: ReviewContainers.suggestionJudge(jobID),
            workspace: workspace,
            model: model,
            defaultAgent: "judge",
            timeout: judgeTimeout,
            promptFile: "/workspace/.meister/prompt-suggestion-judge.md",
            extraFiles: ["/workspace/.meister/suggestion-judge-input.json"],
            message: "Judge the suggestions as instructed."
        )
    }

    public func minerDockerRequest(
        jobID: JobID,
        workspace: URL,
        model: String,
        extraFiles: [String] = []
    ) throws -> DockerRequest {
        try isolatedDockerRequest(
            name: ReviewContainers.miner(jobID),
            workspace: workspace,
            model: model,
            defaultAgent: "miner",
            timeout: agentTimeout,
            promptFile: "/workspace/.meister/prompt.md",
            extraFiles: extraFiles,
            message: "Mine candidate rules as instructed."
        )
    }

    public func run(_ request: JudgeRequest) async -> JudgeRunResult {
        let name = ReviewContainers.judge(request.job.id)
        if await request.isCancelled?() == true {
            return JudgeRunResult(outcome: .containerFailed, containerName: name)
        }
        let dockerRequest: DockerRequest
        do {
            if let runner = docker as? DockerRunner {
                try runner.ensureEgressNetwork()
            }
            dockerRequest = try judgeDockerRequest(
                jobID: request.job.id,
                workspace: request.workspace.root,
                model: request.job.judgeModelID
            )
        } catch {
            return JudgeRunResult(outcome: .containerFailed, containerName: name)
        }
        var transcript = Data()
        if let result = try? await docker.run(dockerRequest) {
            transcript.append(SecretRedactor().redact(result.stdout))
            transcript.append(SecretRedactor().redact(result.stderr))
        }
        let url = request.workspace.root.appendingPathComponent(".meister/judge.json")
        guard let data = try? Data(contentsOf: url) else {
            return JudgeRunResult(outcome: .containerFailed, transcript: transcript, containerName: name)
        }
        return JudgeRunResult(outcome: JudgeMerge.parse(data), transcript: transcript, containerName: name)
    }

    public func runSuggestionJudge(job: Job, workspace: Workspace) async -> JudgeRunResult {
        let name = ReviewContainers.suggestionJudge(job.id)
        let dockerRequest: DockerRequest
        do {
            if let runner = docker as? DockerRunner {
                try runner.ensureEgressNetwork()
            }
            dockerRequest = try suggestionJudgeDockerRequest(
                jobID: job.id,
                workspace: workspace.root,
                model: job.judgeModelID
            )
        } catch {
            return JudgeRunResult(outcome: .containerFailed, containerName: name)
        }
        var transcript = Data()
        if let result = try? await docker.run(dockerRequest) {
            transcript.append(SecretRedactor().redact(result.stdout))
            transcript.append(SecretRedactor().redact(result.stderr))
        }
        transcriptWriter?(job.id, transcript)
        let url = workspace.root.appendingPathComponent(".meister/suggestion-judge.json")
        guard let data = try? Data(contentsOf: url) else {
            return JudgeRunResult(outcome: .containerFailed, transcript: transcript, containerName: name)
        }
        return JudgeRunResult(outcome: JudgeMerge.parse(data), transcript: transcript, containerName: name)
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

        let dockerRequest: DockerRequest
        do {
            dockerRequest = try minerDockerRequest(
                jobID: jobID,
                workspace: workspace.root,
                model: model,
                extraFiles: Self.minerFilePaths(workspace: workspace)
            )
        } catch {
            return MinerRunResult(containerName: name, failed: true, errorMessage: String(describing: error))
        }

        var transcript = Data()
        guard let result = try? await docker.run(dockerRequest) else {
            persistTranscripts(jobID: jobID, chunks: [transcript])
            return MinerRunResult(containerName: name, failed: true, errorMessage: "miner_failed")
        }
        transcript.append(SecretRedactor().redact(result.stdout))
        transcript.append(SecretRedactor().redact(result.stderr))
        persistTranscripts(jobID: jobID, chunks: [transcript])
        if result.timedOut || result.exitCode != 0 {
            return MinerRunResult(containerName: name, failed: true, errorMessage: "miner_failed")
        }
        return MinerRunResult(containerName: name, failed: false)
    }

    private func isolatedDockerRequest(
        name: String,
        workspace: URL,
        model: String,
        defaultAgent: String,
        timeout: Duration,
        promptFile: String,
        extraFiles: [String],
        message: String
    ) throws -> DockerRequest {
        let policy = try OpenCodeConfig.policyJSON(model: model, defaultAgent: defaultAgent)
        let permission = try OpenCodeConfig.permissionJSON()
        var env: [String: String] = [
            "HOME": "/home/meister",
            "XDG_CACHE_HOME": "/home/meister/.cache",
            "OPENCODE_DISABLE_AUTOUPDATE": "true",
            "OPENCODE_AUTO_SHARE": "false",
            "OPENCODE_DISABLE_DEFAULT_PLUGINS": "true",
            "OPENCODE_DISABLE_CLAUDE_CODE": "true",
            "OPENCODE_CONFIG": "/home/meister/.config/opencode/opencode.json",
            "OPENCODE_CONFIG_CONTENT": policy,
            "OPENCODE_PERMISSION": permission,
        ]
        for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"] {
            if let value = providerEnv[key], !value.isEmpty {
                env[key] = value
            }
        }
        // Seed the tmpfs config dir from the sealed bind, then exec. `opencode run`
        // writes package.json next to opencode.json; a RO bind there is EROFS.
        // Message first: `-f` is a yargs array and would swallow a trailing message.
        var argv = [
            "/bin/sh", "-c",
            "cp -a \(Self.configSeed)/. /home/meister/.config/opencode/ && exec \"$@\"",
            "opencode",
            "opencode", "run",
            message,
            "--agent", defaultAgent,
            "--model", model,
            "--format", "json",
            "-f", promptFile,
        ]
        var seen = Set([promptFile])
        for path in extraFiles where seen.insert(path).inserted {
            argv.append(contentsOf: ["-f", path])
        }
        return DockerRequest(
            name: name,
            image: image,
            argv: argv,
            env: env,
            network: "meister-egress",
            workdir: "/workspace",
            publishLoopback: nil,
            user: "1000:1000",
            readOnly: true,
            tmpfs: Self.homeTmpfs,
            binds: [
                .init(source: workspace.path, dest: "/workspace", readOnly: false),
                .init(source: runnerConfig.path, dest: Self.configSeed, readOnly: true),
            ],
            cpus: cpus,
            memory: memory,
            pidsLimit: 256,
            capDropAll: true,
            noNewPrivileges: true,
            ulimitNproc: "256:256",
            ulimitNofile: "1024:1024",
            timeout: timeout,
            injectProviderKeys: true,
            remove: true,
            passThroughEnv: [
                "ANTHROPIC_API_KEY",
                "OPENAI_API_KEY",
                "OPENROUTER_API_KEY",
            ]
        )
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
        let dockerRequest: DockerRequest
        do {
            dockerRequest = try reviewDockerRequest(
                jobID: request.job.id,
                slot: slot,
                workspace: request.workspace.root,
                model: model,
                incremental: request.job.scope == .incremental
            )
        } catch {
            return SlotOutcome(findings: [], valid: false, transcript: Data())
        }
        var transcript = Data()
        if let result = try? await docker.run(dockerRequest) {
            transcript.append(SecretRedactor().redact(result.stdout))
            transcript.append(SecretRedactor().redact(result.stderr))
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
}
