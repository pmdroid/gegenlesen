import Foundation
import Jobs
import Logging
import GegenlesenAgent
import GegenlesenCore
import GegenlesenDeterministic
import Vapor

struct ReviewJobParameters: JobParameters {
    static let jobName = "gegenlesen.review"
    var jobID: JobID
}

struct MineCorpusJobParameters: JobParameters {
    static let jobName = "gegenlesen.mine"
    var corpusJobID: JobID
    var spec: MineJobSpec
}

struct WorkspaceGCJobParameters: JobParameters {
    static let jobName = "gegenlesen.gc"
}

struct LearnSweepJobParameters: JobParameters {
    static let jobName = "gegenlesen.learn-sweep"
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

final class LiveSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var config: GegenlesenConfig
    private var providerEnv: [String: String]

    init(config: GegenlesenConfig, providerEnv: [String: String]) {
        self.config = config
        self.providerEnv = providerEnv
    }

    func snapshot() -> (GegenlesenConfig, [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        return (config, providerEnv)
    }

    func update(config: GegenlesenConfig, providerEnv: [String: String]) {
        lock.lock()
        self.config = config
        self.providerEnv = providerEnv
        lock.unlock()
    }
}

final class JobRuntime: ReviewJobQueuing, @unchecked Sendable {
    let memory: MemoryQueue
    let service: JobService<MemoryQueue>
    let handles: QueueHandles
    let blobs: BlobStore
    let store: Store
    let live: LiveSettings
    let skipAgent: Bool
    private var task: Task<Void, Never>?

    var config: GegenlesenConfig { live.snapshot().0 }

    init(
        store: Store,
        config: GegenlesenConfig,
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
        let runnerConfig = (try? materializeRunnerConfig(
            workingDirectory: workingDirectory,
            dataDir: config.dataDir
        )) ?? URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent("docker/opencode-runner", isDirectory: true)
        let schemasDirectory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent("schemas", isDirectory: true)
        let live = LiveSettings(
            config: config,
            providerEnv: config.providerEnv(from: ProcessInfo.processInfo.environment)
        )
        service.registerJob(
            parameters: ReviewJobParameters.self,
            retryStrategy: .dontRetry
        ) { params, _ in
            do {
                let (config, providerEnv) = live.snapshot()
                let invocation = OpenCodeInvocation(
                    docker: docker,
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
                let (config, providerEnv) = live.snapshot()
                if params.spec.source == .harvest {
                    try await HarvestPipeline(
                        store: store,
                        skipAgent: skipAgent,
                        miner: skipAgent ? nil : OpenCodeInvocation(
                            docker: docker,
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
                        suggestionJudge: skipAgent ? nil : OpenCodeInvocation(
                            docker: docker,
                            image: config.opencodeImage,
                            runnerConfig: runnerConfig,
                            judgeTimeout: Duration.seconds(config.limits.judgeTimeoutSec),
                            providerEnv: providerEnv,
                            schemasDirectory: schemasDirectory
                        ),
                        model: config.models.modelA,
                        embedder: embedder,
                        maxChunks: config.embeddings.maxChunks
                    ).run(jobID: params.corpusJobID)
                } else {
                try await MineCorpusPipeline(
                    store: store,
                    skipAgent: skipAgent,
                    miner: skipAgent ? nil : OpenCodeInvocation(
                        docker: docker,
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
                    suggestionJudge: skipAgent ? nil : OpenCodeInvocation(
                        docker: docker,
                        image: config.opencodeImage,
                        runnerConfig: runnerConfig,
                        judgeTimeout: Duration.seconds(config.limits.judgeTimeoutSec),
                        providerEnv: providerEnv,
                        schemasDirectory: schemasDirectory
                    ),
                    model: config.models.modelA,
                    embedder: embedder,
                    maxChunks: config.embeddings.maxChunks
                ).run(jobID: params.corpusJobID, spec: params.spec)
                }
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
        let runtimeRef = JobRuntimeRef()
        service.registerJob(
            parameters: LearnSweepJobParameters.self,
            retryStrategy: .dontRetry
        ) { _, _ in
            guard let runtime = runtimeRef.runtime else { return }
            try await LearnSweepJob(
                store: runtime.store,
                intervalMinutes: runtime.config.limits.learnIntervalMinutes
            ) { sourceID in
                _ = try await runtime.enqueueLearn(sourceJobID: sourceID)
            }.run()
        }
        if config.limits.learnIntervalMinutes > 0 {
            service.addScheduledJob(LearnSweepJobParameters(), schedule: .everyMinute())
        }
        self.memory = memory
        self.service = service
        self.handles = handles
        self.blobs = store.blobs
        self.store = store
        self.live = live
        self.skipAgent = skipAgent
        runtimeRef.runtime = self
    }

    func apply(_ config: GegenlesenConfig) {
        live.update(
            config: config,
            providerEnv: config.providerEnv(from: ProcessInfo.processInfo.environment)
        )
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

    func enqueueLearn(sourceJobID: JobID) async throws -> JobID {
        try await Self.enqueueLearn(
            sourceJobID: sourceJobID,
            store: store,
            blobs: blobs,
            config: config,
            push: pushMine
        )
    }

    static func enqueueLearn(
        sourceJobID: JobID,
        store: Store,
        blobs: BlobStore,
        config: GegenlesenConfig,
        push: (JobID) async throws -> Void
    ) async throws -> JobID {
        guard let source = try await store.job(id: sourceJobID) else {
            throw Abort(.notFound)
        }
        let id = JobID.generate()
        let now = Date()
        let job = Job(
            id: id,
            createdAt: now,
            updatedAt: now,
            status: .queued,
            scope: .full,
            parentJobID: source.id,
            title: "learn \(source.title ?? source.id.rawValue)",
            repository: source.repository,
            reviewerAModelID: config.models.modelA,
            reviewerBModelID: config.models.modelB,
            judgeModelID: config.judgeModel
        )
        let spec = MineJobSpec(source: .job, sourceJobID: source.id)
        try blobs.ensureLayout()
        try JSONEncoder().encode(spec).write(to: blobs.mineSpecURL(jobID: id.rawValue), options: .atomic)
        try await store.insertJob(job)
        try await store.appendEvent(jobID: id, level: .info, message: "mine_queued")
        try await push(id)
        return id
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

private final class JobRuntimeRef: @unchecked Sendable {
    var runtime: JobRuntime?
}

private struct JobRuntimeKey: StorageKey {
    typealias Value = JobRuntime
}

private struct JobDockerKey: StorageKey {
    typealias Value = any DockerExecuting
}

extension Application {
    var gegenlesenJobs: JobRuntime {
        get {
            guard let value = storage[JobRuntimeKey.self] else {
                fatalError("JobRuntime missing; call configure(_:config:) first")
            }
            return value
        }
        set { storage[JobRuntimeKey.self] = newValue }
    }

    var gegenlesenDocker: any DockerExecuting {
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
