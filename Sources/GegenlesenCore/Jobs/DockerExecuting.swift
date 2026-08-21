import Foundation

public struct DockerRequest: Sendable {
    public var name: String
    public var image: String
    public var argv: [String]
    public var env: [String: String]
    public var network: String?
    public var workdir: String
    public var publishLoopback: (hostPort: Int, containerPort: Int)?
    public var user: String?
    public var readOnly: Bool
    public var tmpfs: [String]
    public var binds: [Bind]
    public var cpus: String?
    public var memory: String?
    public var pidsLimit: Int?
    public var capDropAll: Bool
    public var noNewPrivileges: Bool
    public var ulimitNproc: String?
    public var ulimitNofile: String?
    public var timeout: Duration
    public var injectProviderKeys: Bool
    public var remove: Bool
    /// Names passed as `-e NAME` only; values stay in the docker CLI process environment.
    public var passThroughEnv: [String]
    /// Full stdout snapshot so far. Called from the docker pipe thread; keep it cheap.
    public var onStdout: (@Sendable (Data) -> Void)?

    public struct Bind: Sendable, Equatable {
        public var source: String
        public var dest: String
        public var readOnly: Bool

        public init(source: String, dest: String, readOnly: Bool = false) {
            self.source = source
            self.dest = dest
            self.readOnly = readOnly
        }
    }

    public init(
        name: String,
        image: String,
        argv: [String] = [],
        env: [String: String] = [:],
        network: String? = nil,
        workdir: String = "/",
        publishLoopback: (hostPort: Int, containerPort: Int)? = nil,
        user: String? = nil,
        readOnly: Bool = false,
        tmpfs: [String] = [],
        binds: [Bind] = [],
        cpus: String? = nil,
        memory: String? = nil,
        pidsLimit: Int? = nil,
        capDropAll: Bool = false,
        noNewPrivileges: Bool = false,
        ulimitNproc: String? = nil,
        ulimitNofile: String? = nil,
        timeout: Duration = .seconds(60),
        injectProviderKeys: Bool = false,
        remove: Bool = true,
        passThroughEnv: [String] = [],
        onStdout: (@Sendable (Data) -> Void)? = nil
    ) {
        self.name = name
        self.image = image
        self.argv = argv
        self.env = env
        self.network = network
        self.workdir = workdir
        self.publishLoopback = publishLoopback
        self.user = user
        self.readOnly = readOnly
        self.tmpfs = tmpfs
        self.binds = binds
        self.cpus = cpus
        self.memory = memory
        self.pidsLimit = pidsLimit
        self.capDropAll = capDropAll
        self.noNewPrivileges = noNewPrivileges
        self.ulimitNproc = ulimitNproc
        self.ulimitNofile = ulimitNofile
        self.timeout = timeout
        self.injectProviderKeys = injectProviderKeys
        self.remove = remove
        self.passThroughEnv = passThroughEnv
        self.onStdout = onStdout
    }

    public func dockerCLIArguments() -> [String] {
        var args: [String] = ["run"]
        if remove { args.append("--rm") }
        args += ["--name", name]
        if let publishLoopback {
            args += ["-p", "127.0.0.1:\(publishLoopback.hostPort):\(publishLoopback.containerPort)"]
        }
        if let network {
            args += ["--network", network]
        }
        args += ["--workdir", workdir]
        if let user {
            args += ["--user", user]
        }
        if readOnly {
            args.append("--read-only")
        }
        for spec in tmpfs {
            args += ["--tmpfs", spec]
        }
        for bind in binds {
            var mount = "type=bind,src=\(bind.source),dst=\(bind.dest)"
            if bind.readOnly {
                mount += ",readonly"
            }
            args += ["--mount", mount]
        }
        if let cpus {
            args += ["--cpus", cpus]
        }
        if let memory {
            args += ["--memory", memory]
        }
        if let pidsLimit {
            args += ["--pids-limit", "\(pidsLimit)"]
        }
        if capDropAll {
            args += ["--cap-drop", "ALL"]
        }
        if noNewPrivileges {
            args += ["--security-opt", "no-new-privileges"]
        }
        if let ulimitNproc {
            args += ["--ulimit", "nproc=\(ulimitNproc)"]
        }
        if let ulimitNofile {
            args += ["--ulimit", "nofile=\(ulimitNofile)"]
        }
        let pass = Set(passThroughEnv)
        for key in pass.sorted() {
            args += ["-e", key]
        }
        for key in env.keys.sorted() where !pass.contains(key) {
            args += ["-e", "\(key)=\(env[key] ?? "")"]
        }
        args.append(image)
        args.append(contentsOf: argv)
        return args
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

/// Sandboxed command / openapi_break runner. Tests inject NoopDocker or scripted stdout.
public protocol CommandRunning: Sendable {
    func run(_ request: DockerRequest) async throws -> DockerResult
}

public protocol DockerExecuting: CommandRunning {
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
    public private(set) var requests: [DockerRequest] = []
    public var result: DockerResult

    public init(result: DockerResult = DockerResult(exitCode: 1)) {
        self.result = result
    }

    public func run(_ request: DockerRequest) async throws -> DockerResult {
        requests.append(request)
        return result
    }

    public func kill(containerName: String) async {
        killed.append(containerName)
    }

    public func removeAll(prefix: String) async {
        removedPrefixes.append(prefix)
    }
}

public enum DockerPath: Sendable {
    public static let fallback = "/usr/bin/docker"

    public static let wellKnown = [
        "/usr/local/bin/docker",
        "/usr/bin/docker",
        "/opt/homebrew/bin/docker",
    ]

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        wellKnown: [String] = DockerPath.wellKnown
    ) -> String {
        if let override = environment["GEGENLESEN_DOCKER"], !override.isEmpty {
            return override
        }
        for path in wellKnown where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = "\(directory)/docker"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return fallback
    }
}

public struct DockerCLI: DockerExecuting {
    public var dockerPath: String

    public init(dockerPath: String = DockerPath.resolve()) {
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
