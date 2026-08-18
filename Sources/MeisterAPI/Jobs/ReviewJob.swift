import Foundation
import Jobs
import Logging
import MeisterAgent
import MeisterCore
import MeisterDeterministic
import Vapor

struct ReviewJobParameters: JobParameters {
    static let jobName = "meister.review"
    var jobID: JobID
}

struct MineCorpusJobParameters: JobParameters {
    static let jobName = "meister.mine"
    var corpusJobID: JobID
    var spec: MineJobSpec
}

struct WorkspaceGCJobParameters: JobParameters {
    static let jobName = "meister.gc"
}

actor QueueHandles {
    private var map: [String: UUID] = [:]

    func set(_ jobID: JobID, handle: UUID) {
        map[jobID.rawValue] = handle
    }

    func remove(_ jobID: JobID) -> UUID? {
        map.removeValue(forKey: jobID.rawValue)
    }
}

final class JobRuntime: ReviewJobQueuing, @unchecked Sendable {
    let memory: MemoryQueue
    let service: JobService<MemoryQueue>
    let handles: QueueHandles
    let blobs: BlobStore
    private var task: Task<Void, Never>?

    init(
        store: Store,
        config: MeisterConfig,
        logger: Logger,
        docker: any DockerExecuting,
        skipAgent: Bool,
        workingDirectory: String,
        embedder: (any EmbeddingClient)?
    ) {
        let memory = MemoryQueue()
        var service = JobService(
            memory,
            logger: logger,
            options: .init(processor: .init(numWorkers: 1))
        )
        let identifyTimeout = Duration.seconds(config.limits.identifyTimeoutSec)
        let handles = QueueHandles()
        let runnerConfig = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent("docker/opencode-runner", isDirectory: true)
        let schemasDirectory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent("schemas", isDirectory: true)
        let hostEnv = ProcessInfo.processInfo.environment
        let providerEnv: [String: String] = {
            var env: [String: String] = [:]
            for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"] {
                if let value = hostEnv[key], !value.isEmpty {
                    env[key] = value
                }
            }
            return env
        }()
        service.registerJob(
            parameters: ReviewJobParameters.self,
            retryStrategy: .dontRetry
        ) { params, _ in
            do {
                let invocation = OpenCodeInvocation(
                    docker: docker,
                    http: OpenCodeHTTPClient(),
                    image: config.opencodeImage,
                    runnerConfig: runnerConfig,
                    agentTimeout: Duration.seconds(config.limits.agentTimeoutSec),
                    judgeTimeout: Duration.seconds(config.limits.judgeTimeoutSec),
                    providerEnv: providerEnv,
                    schemasDirectory: schemasDirectory,
                    transcriptWriter: { jobID, data in
                        let url = store.blobs.transcriptURL(jobID: jobID.rawValue, phase: "review")
                        try? FileManager.default.createDirectory(
                            at: url.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try? data.write(to: url, options: .atomic)
                    }
                )
                try await ReviewPipeline(
                    store: store,
                    skipAgent: skipAgent,
                    identifyTimeout: identifyTimeout,
                    deterministicTimeout: Duration.seconds(config.limits.deterministicTimeoutSec),
                    deterministic: DeterministicEngine(
                        docker: docker,
                        image: config.opencodeImage
                    ),
                    reviewer: invocation,
                    judge: invocation,
                    ruleTokenBudget: config.limits.ruleTokenBudget,
                    retrieveK: config.embeddings.retrieveK,
                    maxChunks: config.embeddings.maxChunks,
                    embedder: embedder,
                    miner: skipAgent ? nil : OpenCodeInvocation(
                        docker: docker,
                        http: OpenCodeHTTPClient(),
                        image: config.opencodeImage,
                        runnerConfig: runnerConfig,
                        agentTimeout: Duration.seconds(config.limits.agentTimeoutSec),
                        providerEnv: providerEnv,
                        schemasDirectory: schemasDirectory
                    ),
                    minerModel: config.judgeModel
                ).run(jobID: params.jobID)
            } catch {
                _ = await handles.remove(params.jobID)
                throw error
            }
            _ = await handles.remove(params.jobID)
        }
        service.registerJob(
            parameters: MineCorpusJobParameters.self,
            retryStrategy: .dontRetry
        ) { params, _ in
            do {
                try await MineCorpusPipeline(
                    store: store,
                    skipAgent: skipAgent,
                    miner: skipAgent ? nil : OpenCodeInvocation(
                        docker: docker,
                        http: OpenCodeHTTPClient(),
                        image: config.opencodeImage,
                        runnerConfig: runnerConfig,
                        agentTimeout: Duration.seconds(config.limits.agentTimeoutSec),
                        providerEnv: providerEnv,
                        schemasDirectory: schemasDirectory,
                        transcriptWriter: { jobID, data in
                            let url = store.blobs.transcriptURL(jobID: jobID.rawValue, phase: "mine")
                            try? FileManager.default.createDirectory(
                                at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try? data.write(to: url, options: .atomic)
                        }
                    ),
                    model: config.judgeModel,
                    embedder: embedder,
                    maxChunks: config.embeddings.maxChunks
                ).run(jobID: params.corpusJobID, spec: params.spec)
            } catch {
                _ = await handles.remove(params.corpusJobID)
                throw error
            }
            _ = await handles.remove(params.corpusJobID)
        }
        service.registerJob(
            parameters: WorkspaceGCJobParameters.self,
            retryStrategy: .dontRetry
        ) { _, _ in
            try await WorkspaceGCJob(store: store).run()
        }
        service.addScheduledJob(WorkspaceGCJobParameters(), schedule: .hourly())
        self.memory = memory
        self.service = service
        self.handles = handles
        self.blobs = store.blobs
    }

    func start() {
        task = Task { [service] in
            try? await service.run()
        }
    }

    func shutdown() async {
        await memory.stop()
        task?.cancel()
        task = nil
    }

    func pushReview(_ id: JobID) async throws {
        let handle = try await service.push(ReviewJobParameters(jobID: id))
        await handles.set(id, handle: handle)
    }

    func pushMine(_ id: JobID) async throws {
        let spec = loadMineSpec(id) ?? MineJobSpec(source: .corpus)
        let handle = try await service.push(MineCorpusJobParameters(corpusJobID: id, spec: spec))
        await handles.set(id, handle: handle)
    }

    private func loadMineSpec(_ id: JobID) -> MineJobSpec? {
        let url = blobs.mineSpecURL(jobID: id.rawValue)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MineJobSpec.self, from: data)
    }

    func cancel(_ id: JobID) async {
        if let handle = await handles.remove(id) {
            try? await service.cancelJob(jobID: handle)
        }
    }
}

private struct JobRuntimeKey: StorageKey {
    typealias Value = JobRuntime
}

private struct JobDockerKey: StorageKey {
    typealias Value = any DockerExecuting
}

extension Application {
    var meisterJobs: JobRuntime {
        get {
            guard let value = storage[JobRuntimeKey.self] else {
                fatalError("JobRuntime missing; call configure(_:config:) first")
            }
            return value
        }
        set { storage[JobRuntimeKey.self] = newValue }
    }

    var meisterDocker: any DockerExecuting {
        get { storage[JobDockerKey.self] ?? DockerRunner() }
        set { storage[JobDockerKey.self] = newValue }
    }
}

struct JobRuntimeLifecycle: LifecycleHandler {
    func shutdown(_ application: Application) {
        guard let runtime = application.storage[JobRuntimeKey.self] else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await runtime.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}
