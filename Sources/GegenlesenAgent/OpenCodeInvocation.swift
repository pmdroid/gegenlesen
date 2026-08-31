import Foundation
import GegenlesenCore

public struct OpenCodeInvocation: ReviewerRunning, MinerRunning, JudgeRunning, SuggestionJudging, Sendable {
    public var docker: any DockerExecuting
    public var image: String
    public var engineImages: [String: String]
    public var runnerConfig: URL
    public var cpus: String
    public var memory: String
    public var agentTimeout: Duration
    public var judgeTimeout: Duration
    public var providerEnv: [String: String]
    public var schemasDirectory: URL?
    public var transcriptWriter: (@Sendable (JobID, String, Data) -> Void)?
    public var prepareRunnerConfig: (@Sendable (JobID, String?) async throws -> Void)?

    public init(
        docker: any DockerExecuting,
        image: String,
        engineImages: [String: String] = [:],
        runnerConfig: URL,
        cpus: String = ProcessInfo.processInfo.environment["GEGENLESEN_DOCKER_CPUS"] ?? "2",
        memory: String = ProcessInfo.processInfo.environment["GEGENLESEN_DOCKER_MEMORY"] ?? "4g",
        agentTimeout: Duration = .seconds(900),
        judgeTimeout: Duration = .seconds(300),
        providerEnv: [String: String] = [:],
        schemasDirectory: URL? = nil,
        transcriptWriter: (@Sendable (JobID, String, Data) -> Void)? = nil,
        prepareRunnerConfig: (@Sendable (JobID, String?) async throws -> Void)? = nil
    ) {
        self.docker = docker
        self.image = image
        self.engineImages = engineImages
        self.runnerConfig = runnerConfig
        self.cpus = cpus
        self.memory = memory
        self.agentTimeout = agentTimeout
        self.judgeTimeout = judgeTimeout
        self.providerEnv = providerEnv
        self.schemasDirectory = schemasDirectory
        self.transcriptWriter = transcriptWriter
        self.prepareRunnerConfig = prepareRunnerConfig
    }

    /// Writable spots on a `--read-only` root. OpenCode writes `~/.cache/opencode/version`
    /// and `~/.config/opencode/package.json` (`opencode run`).
    static let configSeed = "/opt/gegenlesen/opencode"
    static let configTmpfs = [
        "/home/gegenlesen/.config/opencode:rw,nosuid,nodev,uid=1000,gid=1000,size=64m",
        "/home/gegenlesen/.config/opencode-state:rw,nosuid,nodev,uid=1000,gid=1000,size=64m",
    ]

    public func run(_ request: AgentReviewRequest) async -> AgentReviewResult {
        let jobID = request.job.id
        let nameA = Self.containerName(jobID: jobID, slot: .modelA)
        let nameB = Self.containerName(jobID: jobID, slot: .modelB)
        let judgeName = "gegenlesen-judge-\(jobID.rawValue)"
        do {
            try await prepareRunnerConfig?(request.job.id, request.job.repository)
            if let runner = docker as? DockerRunner {
                try runner.ensureEgressNetwork()
            }
            try Quarantine.run(workspace: request.workspace)
            try DockerRunner.chownWorkspace(request.workspace.root)
            let diffURL = request.workspace.root.appendingPathComponent(".gegenlesen/diff.patch")
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
            let message = String(describing: error)
            return AgentReviewResult(
                findings: [],
                validFileCount: 0,
                failed: request.newWork,
                errorMessage: message,
                payloadJSON: Self.reviewEventPayload(errorMessage: message, transcripts: []),
                containerNameA: nameA,
                containerNameB: nameB,
                containerName: judgeName
            )
        }

        let known = Set(request.rules.map(\.id))
        let resultA = await runSlot(
            request,
            slot: .modelA,
            engine: request.job.reviewerAEngine,
            model: request.job.reviewerAModelID,
            known: known
        )
        if resultA.providerAuth {
            persistTranscripts(jobID: jobID, phase: "review", chunks: [resultA.transcript])
            persistAgentCopies(workspace: request.workspace, jobID: jobID)
            let errorMessage = ReviewFailureClass.providerAuth.rawValue
            return AgentReviewResult(
                findings: resultA.findings,
                validFileCount: resultA.valid ? 1 : 0,
                failed: true,
                errorMessage: errorMessage,
                payloadJSON: Self.reviewEventPayload(
                    errorMessage: errorMessage,
                    transcripts: [resultA.transcript]
                ),
                containerNameA: nameA,
                containerNameB: nameB,
                containerName: judgeName
            )
        }

        let resultB = await runSlot(
            request,
            slot: .modelB,
            engine: request.job.reviewerBEngine,
            model: request.job.reviewerBModelID,
            known: known
        )
        if resultB.providerAuth {
            persistTranscripts(jobID: jobID, phase: "review", chunks: [resultA.transcript, resultB.transcript])
            persistAgentCopies(workspace: request.workspace, jobID: jobID)
            let errorMessage = ReviewFailureClass.providerAuth.rawValue
            return AgentReviewResult(
                findings: resultA.findings + resultB.findings,
                validFileCount: (resultA.valid ? 1 : 0) + (resultB.valid ? 1 : 0),
                failed: true,
                errorMessage: errorMessage,
                payloadJSON: Self.reviewEventPayload(
                    errorMessage: errorMessage,
                    transcripts: [resultA.transcript, resultB.transcript]
                ),
                containerNameA: nameA,
                containerNameB: nameB,
                containerName: judgeName
            )
        }

        let findings = resultA.valid && resultB.valid
            ? resultA.findings + resultB.findings
            : resultA.valid
                ? resultA.findings
                : resultB.findings
        let valid = (resultA.valid ? 1 : 0) + (resultB.valid ? 1 : 0)

        if request.newWork && valid == 0 {
            persistTranscripts(jobID: jobID, phase: "review", chunks: [resultA.transcript, resultB.transcript])
            persistAgentCopies(workspace: request.workspace, jobID: jobID)
            let errorMessage = "reviewer_no_findings_file"
            return AgentReviewResult(
                findings: findings,
                validFileCount: valid,
                failed: true,
                errorMessage: errorMessage,
                payloadJSON: Self.reviewEventPayload(
                    errorMessage: errorMessage,
                    transcripts: [resultA.transcript, resultB.transcript]
                ),
                containerNameA: nameA,
                containerNameB: nameB,
                containerName: judgeName
            )
        }

        if valid == 1, !resultA.valid || !resultB.valid {
            if request.reviewStrictMode {
                persistTranscripts(jobID: jobID, phase: "review", chunks: [resultA.transcript, resultB.transcript])
                persistAgentCopies(workspace: request.workspace, jobID: jobID)
                let failedResult = resultA.valid ? resultB : resultA
                let errorMessage = failedResult.validationError ?? "reviewer_validation_failed"
                return AgentReviewResult(
                    findings: findings,
                    validFileCount: valid,
                    failed: true,
                    errorMessage: errorMessage,
                    payloadJSON: Self.reviewEventPayload(
                        errorMessage: errorMessage,
                        transcripts: [resultA.transcript, resultB.transcript]
                    ),
                    containerNameA: nameA,
                    containerNameB: nameB,
                    containerName: judgeName
                )
            }
            let failedSlot: ReviewerSlot = resultA.valid ? .modelB : .modelA
            let failedResult = resultA.valid ? resultB : resultA
            let survivingSlot: ReviewerSlot = resultA.valid ? .modelA : .modelB
            let failedEngine = failedSlot == .modelA
                ? request.job.reviewerAEngine
                : request.job.reviewerBEngine
            let degradedError = failedResult.validationError ?? "reviewer_validation_failed"
            try? PromptRenderer(schemasDirectory: schemasDirectory).writeJudgePrompt(
                workspace: request.workspace,
                singleReviewerSlot: survivingSlot
            )
            persistTranscripts(jobID: jobID, phase: "review", chunks: [resultA.transcript, resultB.transcript])
            persistAgentCopies(workspace: request.workspace, jobID: jobID)
            return AgentReviewResult(
                findings: findings,
                validFileCount: valid,
                failed: false,
                containerNameA: nameA,
                containerNameB: nameB,
                containerName: judgeName,
                reviewDegraded: true,
                reviewDegradedSlot: failedSlot.rawValue,
                reviewDegradedEngine: failedEngine,
                reviewDegradedError: degradedError
            )
        }

        persistTranscripts(jobID: jobID, phase: "review", chunks: [resultA.transcript, resultB.transcript])
        persistAgentCopies(workspace: request.workspace, jobID: jobID)
        return AgentReviewResult(
            findings: findings,
            validFileCount: valid,
            failed: false,
            containerNameA: nameA,
            containerNameB: nameB,
            containerName: judgeName
        )
    }

    static func reviewEventPayload(errorMessage: String, transcripts: [Data]) -> String? {
        var object: [String: Any] = ["message": errorMessage]
        let text = transcripts.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
        if let parsed = openRouterError(in: text) {
            object["provider"] = "openrouter"
            object["status"] = parsed.status
            object["body"] = parsed.body
        }
        let encoded = JobEvent.payloadJSON(object)
        object["error_class"] = ReviewFailureClass.classify(
            errorMessage: errorMessage,
            payloadJSON: encoded
        ).rawValue
        return JobEvent.payloadJSON(object)
    }

    static func openRouterError(in text: String) -> (status: Int, body: String)? {
        guard !text.isEmpty else { return nil }
        let status = ReviewFailureClass.providerAuthHTTPStatus(in: text) ?? [429, 500, 502, 503].first(where: { code in
            text.contains("\"status\":\(code)")
                || text.contains("\"status\": \(code)")
                || text.contains("\"code\":\(code)")
                || text.contains("\"code\": \(code)")
                || text.contains("HTTP \(code)")
        })
        guard let status else { return nil }
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        return (status, body)
    }

    static func isProviderAuth(_ transcript: Data) -> Bool {
        ReviewFailureClass.providerAuthHTTPStatus(in: String(data: transcript, encoding: .utf8)) != nil
    }

    public static func containerName(jobID: JobID, slot: ReviewerSlot) -> String {
        ReviewContainers.slot(jobID, slot)
    }

    /// Attach only files that exist. Job learn stages `job/` + findings; corpus mines do not.
    public static func minerFilePaths(workspace: Workspace) -> [String] {
        let candidates = [
            ".gegenlesen/prompt.md",
            ".gegenlesen/harvest-scan.json",
            ".gegenlesen/architecture-draft.md",
            ".gegenlesen/findings.json",
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
            "/workspace/.gegenlesen/rules.json",
            "/workspace/.gegenlesen/diff.patch",
        ]
        if incremental {
            paths.append("/workspace/.gegenlesen/parent-findings.json")
        }
        return paths
    }

    public func acpReviewDockerRequest(
        jobID: JobID,
        slot: ReviewerSlot,
        workspace: URL,
        engine: String,
        model: String,
        incremental: Bool = false
    ) throws -> DockerRequest {
        let outputPath = "/workspace/.gegenlesen/findings-\(slot.rawValue).json"
        let promptFile = "/workspace/.gegenlesen/prompt-\(slot.rawValue).md"
        let timeoutSec = max(1, Int(agentTimeout.components.seconds))
        let agentCommand = ACPEngines.agentCommand(engine: engine, model: model)
        guard !agentCommand.isEmpty else {
            throw AgentEngineError.unknownEngine(engine)
        }
        var argv = [
            "acp-runner",
            "--prompt-file", promptFile,
            "--message", "Investigate the change thoroughly, then write findings as instructed.",
            "--output", "findings",
            "--output-path", outputPath,
            "--timeout-sec", "\(timeoutSec)",
            "--",
        ]
        argv.append(contentsOf: agentCommand)
        var env = ACPEngines.agentEnv(engine: engine, model: model)
        env["NODE_NO_WARNINGS"] = "1"
        let runnerImage = engineImages[engine] ?? image
        var request = AgentSandbox.dockerRequest(
            name: Self.containerName(jobID: jobID, slot: slot),
            payload: AgentContainerPayload(
                image: runnerImage,
                argv: argv,
                env: env,
                tmpfs: ACPEngines.engineTmpfs(engine: engine)
            ),
            workspace: workspace,
            providerEnv: providerEnv,
            cpus: cpus,
            memory: memory,
            timeout: agentTimeout
        )
        _ = incremental
        if let writer = transcriptWriter {
            let redactor = SecretRedactor()
            let livePhase = slot == .modelA ? "review_a" : "review_b"
            request.onStdout = { data in
                writer(jobID, livePhase, redactor.redact(data))
            }
        }
        return request
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
            promptFile: "/workspace/.gegenlesen/prompt-\(slot.rawValue).md",
            extraFiles: Self.reviewFilePaths(incremental: incremental),
            message: "Investigate the change thoroughly, then write findings as instructed.",
            jobID: jobID,
            livePhase: slot == .modelA ? "review_a" : "review_b"
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
            promptFile: "/workspace/.gegenlesen/prompt-judge.md",
            extraFiles: [
                "/workspace/.gegenlesen/judge-input.json",
                "/workspace/.gegenlesen/diff.patch",
                "/workspace/.gegenlesen/files.json",
            ],
            message: "For each finding, Read the cited source and keep only claims the code supports, then write verdicts.",
            jobID: jobID,
            livePhase: "judge"
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
            defaultAgent: "suggestion-judge",
            timeout: judgeTimeout,
            promptFile: "/workspace/.gegenlesen/prompt-suggestion-judge.md",
            extraFiles: ["/workspace/.gegenlesen/suggestion-judge-input.json"],
            message: "Judge the suggestions as instructed.",
            jobID: jobID,
            livePhase: "suggestion_judge"
        )
    }

    public func minerDockerRequest(
        jobID: JobID,
        workspace: URL,
        engine: String,
        model: String,
        extraFiles: [String] = [],
        defaultAgent: String = "miner"
    ) throws -> DockerRequest {
        let runnerImage = engineImages[engine] ?? image
        return try isolatedDockerRequest(
            name: ReviewContainers.miner(jobID),
            workspace: workspace,
            model: model,
            defaultAgent: defaultAgent,
            timeout: agentTimeout,
            promptFile: "/workspace/.gegenlesen/prompt.md",
            extraFiles: extraFiles,
            message: "Mine candidate rules as instructed.",
            jobID: jobID,
            livePhase: "mine",
            runnerImage: runnerImage
        )
    }

    public func run(_ request: JudgeRequest) async -> JudgeRunResult {
        let name = ReviewContainers.judge(request.job.id)
        if await request.isCancelled?() == true {
            return JudgeRunResult(outcome: .containerFailed, containerName: name)
        }
        let dockerRequest: DockerRequest
        do {
            try await prepareRunnerConfig?(request.job.id, request.job.repository)
            if let runner = docker as? DockerRunner {
                try runner.ensureEgressNetwork()
            }
            // TODO(#40): dispatch judge by job.judgeEngine when non-opencode judges land
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
        let url = request.workspace.root.appendingPathComponent(".gegenlesen/judge.json")
        guard let data = try? Data(contentsOf: url) else {
            return JudgeRunResult(outcome: .containerFailed, transcript: transcript, containerName: name)
        }
        return JudgeRunResult(outcome: JudgeMerge.parse(data), transcript: transcript, containerName: name)
    }

    public func runSuggestionJudge(job: Job, workspace: Workspace) async -> SuggestionJudgeRunResult {
        let name = ReviewContainers.suggestionJudge(job.id)
        do {
            try await prepareRunnerConfig?(job.id, job.repository)
            if let runner = docker as? DockerRunner {
                try runner.ensureEgressNetwork()
            }
            try DockerRunner.chownWorkspace(workspace.root)
        } catch {
            return SuggestionJudgeRunResult(
                outcome: .failed,
                containerName: name,
                errorMessage: String(describing: error)
            )
        }
        let dockerRequest: DockerRequest
        do {
            dockerRequest = try suggestionJudgeDockerRequest(
                jobID: job.id,
                workspace: workspace.root,
                model: job.judgeModelID
            )
        } catch {
            return SuggestionJudgeRunResult(
                outcome: .failed,
                containerName: name,
                errorMessage: String(describing: error)
            )
        }
        var transcript = Data()
        let result: DockerResult
        do {
            result = try await docker.run(dockerRequest)
            transcript.append(SecretRedactor().redact(result.stdout))
            transcript.append(SecretRedactor().redact(result.stderr))
        } catch {
            persistTranscripts(jobID: job.id, phase: "suggestion_judge", chunks: [transcript])
            return SuggestionJudgeRunResult(
                outcome: .failed,
                transcript: transcript,
                containerName: name,
                errorMessage: String(describing: error)
            )
        }
        persistTranscripts(jobID: job.id, phase: "suggestion_judge", chunks: [transcript])
        let url = workspace.root.appendingPathComponent(".gegenlesen/suggestion-judge.json")
        guard let data = try? Data(contentsOf: url) else {
            return SuggestionJudgeRunResult(
                outcome: .failed,
                transcript: transcript,
                containerName: name,
                errorMessage: Self.suggestionJudgeMissingReason(result),
                exitCode: result.exitCode,
                timedOut: result.timedOut
            )
        }
        let outcome = SuggestionJudge.parse(data)
        if case .failed = outcome {
            return SuggestionJudgeRunResult(
                outcome: .failed,
                transcript: transcript,
                containerName: name,
                errorMessage: "invalid_suggestion_judge_file",
                exitCode: result.exitCode,
                timedOut: result.timedOut
            )
        }
        return SuggestionJudgeRunResult(
            outcome: outcome,
            transcript: transcript,
            containerName: name,
            exitCode: result.exitCode,
            timedOut: result.timedOut
        )
    }

    private static func suggestionJudgeMissingReason(_ result: DockerResult) -> String {
        if result.timedOut { return "timed_out" }
        if result.oom { return "oom" }
        if result.exitCode != 0 { return "exit_\(result.exitCode)" }
        return "missing_suggestion_judge_file"
    }

    public func runMiner(
        jobID: JobID,
        workspace: Workspace,
        engine: String,
        model: String,
        isCancelled: (@Sendable () async -> Bool)? = nil
    ) async -> MinerRunResult {
        guard engine == AgentEngineID.opencode else {
            return MinerRunResult(
                containerName: ReviewContainers.miner(jobID),
                failed: true,
                errorMessage: "mine_engine_requires_opencode"
            )
        }
        let name = ReviewContainers.miner(jobID)
        do {
            try await prepareRunnerConfig?(jobID, nil)
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
                engine: engine,
                model: model,
                extraFiles: Self.minerFilePaths(workspace: workspace),
                defaultAgent: FileManager.default.fileExists(
                    atPath: workspace.root.appendingPathComponent(".gegenlesen/harvest-scan.json").path
                ) ? "harvester" : "miner"
            )
        } catch {
            return MinerRunResult(containerName: name, failed: true, errorMessage: String(describing: error))
        }

        var transcript = Data()
        guard let result = try? await docker.run(dockerRequest) else {
            persistTranscripts(jobID: jobID, phase: "mine", chunks: [transcript])
            return MinerRunResult(containerName: name, failed: true, errorMessage: "miner_failed")
        }
        transcript.append(SecretRedactor().redact(result.stdout))
        transcript.append(SecretRedactor().redact(result.stderr))
        persistTranscripts(jobID: jobID, phase: "mine", chunks: [transcript])
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
        message: String,
        jobID: JobID? = nil,
        livePhase: String? = nil,
        runnerImage: String? = nil
    ) throws -> DockerRequest {
        let policy = try OpenCodeConfig.policyJSON(model: model, defaultAgent: defaultAgent)
        let permission = try OpenCodeConfig.permissionJSON()
        let env: [String: String] = [
            "OPENCODE_DISABLE_AUTOUPDATE": "true",
            "OPENCODE_AUTO_SHARE": "false",
            "OPENCODE_DISABLE_DEFAULT_PLUGINS": "true",
            "OPENCODE_DISABLE_CLAUDE_CODE": "true",
            "OPENCODE_EXPERIMENTAL_LSP_TOOL": "true",
            "OPENCODE_CONFIG": "/home/gegenlesen/.config/opencode/opencode.json",
            "OPENCODE_CONFIG_CONTENT": policy,
            "OPENCODE_PERMISSION": permission,
        ]
        // Seed the tmpfs config dir from the sealed bind, then exec. `opencode run`
        // writes package.json next to opencode.json; a RO bind there is EROFS.
        // Message first: `-f` is a yargs array and would swallow a trailing message.
        var argv = [
            "/bin/sh", "-c",
            "cp -a \(Self.configSeed)/. /home/gegenlesen/.config/opencode/ && exec \"$@\"",
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
        var request = AgentSandbox.dockerRequest(
            name: name,
            payload: AgentContainerPayload(
                image: runnerImage ?? image,
                argv: argv,
                env: env,
                tmpfs: Self.configTmpfs,
                binds: [
                    .init(source: runnerConfig.path, dest: Self.configSeed, readOnly: true),
                ]
            ),
            workspace: workspace,
            providerEnv: providerEnv,
            cpus: cpus,
            memory: memory,
            timeout: timeout
        )
        if let jobID, let livePhase, let writer = transcriptWriter {
            let redactor = SecretRedactor()
            request.onStdout = { data in
                writer(jobID, livePhase, redactor.redact(data))
            }
        }
        return request
    }

    private struct SlotOutcome: Sendable {
        var findings: [Finding]
        var valid: Bool
        var transcript: Data
        var providerAuth: Bool
        var validationError: String?
    }

    private func appendRetryNotice(workspace: Workspace, slot: ReviewerSlot, errors: String) throws {
        let promptURL = workspace.root.appendingPathComponent(".gegenlesen/prompt-\(slot.rawValue).md")
        let existing = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? ""
        let notice = """

        ## Retry

        Previous output failed validation: \(errors)
        """
        try (existing + notice).write(to: promptURL, atomically: true, encoding: .utf8)
    }

    private func runSlot(
        _ request: AgentReviewRequest,
        slot: ReviewerSlot,
        engine: String,
        model: String,
        known: Set<RuleID>
    ) async -> SlotOutcome {
        var combinedTranscript = Data()
        var lastOutcome = SlotOutcome(
            findings: [],
            valid: false,
            transcript: Data(),
            providerAuth: false,
            validationError: "reviewer_no_findings_file"
        )
        for attempt in 1...2 {
            let outcome = await executeSlotAttempt(
                request,
                slot: slot,
                engine: engine,
                model: model,
                known: known
            )
            combinedTranscript.append(outcome.transcript)
            lastOutcome = SlotOutcome(
                findings: outcome.findings,
                valid: outcome.valid,
                transcript: combinedTranscript,
                providerAuth: outcome.providerAuth,
                validationError: outcome.validationError
            )
            if outcome.valid || outcome.providerAuth {
                return lastOutcome
            }
            if attempt == 1, let error = outcome.validationError {
                try? appendRetryNotice(workspace: request.workspace, slot: slot, errors: error)
                continue
            }
            break
        }
        return lastOutcome
    }

    private func executeSlotAttempt(
        _ request: AgentReviewRequest,
        slot: ReviewerSlot,
        engine: String,
        model: String,
        known: Set<RuleID>
    ) async -> SlotOutcome {
        if await request.isCancelled?() == true {
            return SlotOutcome(
                findings: [],
                valid: false,
                transcript: Data(),
                providerAuth: false,
                validationError: "cancelled"
            )
        }
        let dockerRequest: DockerRequest
        do {
            if ACPEngines.usesACP(engine) {
                dockerRequest = try acpReviewDockerRequest(
                    jobID: request.job.id,
                    slot: slot,
                    workspace: request.workspace.root,
                    engine: engine,
                    model: model,
                    incremental: request.job.scope == .incremental
                )
            } else {
                dockerRequest = try reviewDockerRequest(
                    jobID: request.job.id,
                    slot: slot,
                    workspace: request.workspace.root,
                    model: model,
                    incremental: request.job.scope == .incremental
                )
            }
        } catch {
            return SlotOutcome(
                findings: [],
                valid: false,
                transcript: Data(),
                providerAuth: false,
                validationError: String(describing: error)
            )
        }
        var transcript = Data()
        var providerAuth = false
        do {
            let result = try await docker.run(dockerRequest)
            transcript.append(SecretRedactor().redact(Data(result.outputText.utf8)))
            if result.exitCode != 0 || result.timedOut {
                providerAuth = DockerRunner.providerAuthStatus(in: result) != nil
            }
        } catch {
            let body = SecretRedactor().redact(String(describing: error))
            transcript.append(Data(body.utf8))
            providerAuth = Self.isProviderAuth(transcript)
        }

        let url = FindingsParser.findingsURL(workspace: request.workspace, slot: slot)
        let shared = request.workspace.root.appendingPathComponent(".gegenlesen/findings.json")
        let data = (try? Data(contentsOf: url)) ?? (try? Data(contentsOf: shared))
        guard let data else {
            return SlotOutcome(
                findings: [],
                valid: false,
                transcript: transcript,
                providerAuth: providerAuth,
                validationError: "reviewer_no_findings_file"
            )
        }
        do {
            let parsed = try FindingsParser.parse(
                file: data,
                workspace: request.workspace,
                knownRuleIDs: known,
                jobID: request.job.id,
                slot: slot
            )
            return SlotOutcome(
                findings: parsed.findings,
                valid: true,
                transcript: transcript,
                providerAuth: false,
                validationError: nil
            )
        } catch {
            return SlotOutcome(
                findings: [],
                valid: false,
                transcript: transcript,
                providerAuth: providerAuth,
                validationError: String(describing: error)
            )
        }
    }

    private func persistTranscripts(jobID: JobID, phase: String, chunks: [Data]) {
        var combined = Data()
        for chunk in chunks {
            combined.append(SecretRedactor().redact(chunk))
        }
        guard !combined.isEmpty else { return }
        transcriptWriter?(jobID, phase, combined)
    }

    private func persistAgentCopies(workspace: Workspace, jobID: JobID) {
        let fm = FileManager.default
        let dest = workspace.root.appendingPathComponent(".gegenlesen/agent-findings.json")
        for name in ["findings-model_a.json", "findings-model_b.json", "findings.json"] {
            let source = workspace.root.appendingPathComponent(".gegenlesen/\(name)")
            if fm.fileExists(atPath: source.path) {
                try? fm.removeItem(at: dest)
                try? fm.copyItem(at: source, to: dest)
                return
            }
        }
    }
}
