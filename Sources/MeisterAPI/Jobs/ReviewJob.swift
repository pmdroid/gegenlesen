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
    private var task: Task<Void, Never>?

    init(
        store: Store,
        config: MeisterConfig,
        logger: Logger,
        docker: any DockerExecuting,
        skipAgent: Bool,
        workingDirectory: String
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
                try await ReviewPipeline(
                    store: store,
                    skipAgent: skipAgent,
                    identifyTimeout: identifyTimeout,
                    deterministicTimeout: Duration.seconds(config.limits.deterministicTimeoutSec),
                    deterministic: DeterministicEngine(),
                    reviewer: OpenCodeInvocation(
                        docker: docker,
                        image: config.opencodeImage,
                        runnerConfig: runnerConfig,
                        agentTimeout: Duration.seconds(config.limits.agentTimeoutSec),
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
                ).run(jobID: params.jobID)
            } catch {
                _ = await handles.remove(params.jobID)
                throw error
            }
            _ = await handles.remove(params.jobID)
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
        get { storage[JobDockerKey.self] ?? DockerCLI() }
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
