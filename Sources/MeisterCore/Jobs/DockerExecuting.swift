import Foundation

public struct DockerRequest: Sendable {
    public var name: String
    public var image: String
    public var argv: [String]
    public var env: [String: String]
    public var network: String?
    public var workdir: String
    public var timeout: Duration
    public var injectProviderKeys: Bool

    public init(
        name: String,
        image: String,
        argv: [String] = [],
        env: [String: String] = [:],
        network: String? = nil,
        workdir: String = "/",
        timeout: Duration = .seconds(60),
        injectProviderKeys: Bool = false
    ) {
        self.name = name
        self.image = image
        self.argv = argv
        self.env = env
        self.network = network
        self.workdir = workdir
        self.timeout = timeout
        self.injectProviderKeys = injectProviderKeys
    }
}

public struct DockerResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var oom: Bool

    public init(
        exitCode: Int32,
        stdout: Data = Data(),
        stderr: Data = Data(),
        timedOut: Bool = false,
        oom: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.oom = oom
    }
}

public protocol DockerExecuting: Sendable {
    func run(_ request: DockerRequest) async throws -> DockerResult
    func kill(containerName: String) async
    func removeAll(prefix: String) async
}

public struct NoopDocker: DockerExecuting {
    public init() {}

    public func run(_ request: DockerRequest) async throws -> DockerResult {
        DockerResult(exitCode: 1, stderr: Data("docker not wired".utf8))
    }

    public func kill(containerName: String) async {}

    public func removeAll(prefix: String) async {}
}

public actor RecordingDocker: DockerExecuting {
    public private(set) var removedPrefixes: [String] = []
    public private(set) var killed: [String] = []

    public init() {}

    public func run(_ request: DockerRequest) async throws -> DockerResult {
        DockerResult(exitCode: 1)
    }

    public func kill(containerName: String) async {
        killed.append(containerName)
    }

    public func removeAll(prefix: String) async {
        removedPrefixes.append(prefix)
    }
}

public struct DockerCLI: DockerExecuting {
    public var dockerPath: String

    public init(dockerPath: String = "/usr/bin/docker") {
        self.dockerPath = dockerPath
    }

    public func run(_ request: DockerRequest) async throws -> DockerResult {
        DockerResult(exitCode: 1, stderr: Data("docker run not wired".utf8))
    }

    public func kill(containerName: String) async {
        _ = try? runDocker(["kill", containerName])
        _ = try? runDocker(["rm", "-f", containerName])
    }

    public func removeAll(prefix: String) async {
        guard let listed = try? runDocker([
            "ps", "-a",
            "--filter", "name=\(prefix)",
            "--format", "{{.Names}}",
        ]) else {
            return
        }
        let names = String(data: listed.stdout, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix(prefix) } ?? []
        for name in names {
            _ = try? runDocker(["rm", "-f", name])
        }
    }

    private func runDocker(_ arguments: [String]) throws -> DockerResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSTemporaryDirectory(),
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return DockerResult(exitCode: 127)
        }
        process.waitUntilExit()
        return DockerResult(
            exitCode: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }
}
