import Darwin
import Foundation
import MeisterCore

public enum DockerRunnerError: Error, Sendable, Equatable {
    case networkCreateFailed(String)
}

/// Process wait is not isolated: `run` and `kill` (and two `run`s) may overlap.
public final class DockerRunner: DockerExecuting, @unchecked Sendable {
    public static let maxCaptureBytes = 20 * 1024 * 1024
    public static let egressNetwork = "meister-egress"

    public let dockerPath: String

    public init(dockerPath: String = DockerPath.resolve()) {
        self.dockerPath = dockerPath
    }

    public func run(_ request: DockerRequest) async throws -> DockerResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: dockerPath)
        process.arguments = request.dockerCLIArguments()
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": NSTemporaryDirectory(),
        ]
        for key in request.passThroughEnv {
            if let value = request.env[key], !value.isEmpty {
                environment[key] = value
            }
        }
        if request.injectProviderKeys {
            let host = ProcessInfo.processInfo.environment
            for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"] {
                if environment[key] == nil, let value = host[key], !value.isEmpty {
                    environment[key] = value
                }
            }
        }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let capture = CaptureBox(limit: Self.maxCaptureBytes)
        let name = request.name
        let dockerPath = self.dockerPath
        stdout.fileHandleForReading.readabilityHandler = { handle in
            if !capture.append(handle.availableData, stream: .stdout) {
                Self.killSync(dockerPath: dockerPath, name: name)
                process.terminate()
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if !capture.append(handle.availableData, stream: .stderr) {
                Self.killSync(dockerPath: dockerPath, name: name)
                process.terminate()
            }
        }

        let deadline = ContinuousClock.now + request.timeout
        let once = ResumeOnce()
        let watchdog = Task {
            try await Task.sleep(until: deadline, clock: .continuous)
            Self.killSync(dockerPath: dockerPath, name: name)
            process.terminate()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                once.resume { cont.resume() }
            }
            do {
                try process.run()
            } catch {
                once.resume { cont.resume() }
                return
            }
            if !process.isRunning {
                once.resume { cont.resume() }
            }
        }
        watchdog.cancel()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if !capture.isCapped {
            _ = capture.append(stdout.fileHandleForReading.readDataToEndOfFile(), stream: .stdout)
            _ = capture.append(stderr.fileHandleForReading.readDataToEndOfFile(), stream: .stderr)
        } else {
            _ = try? stdout.fileHandleForReading.readToEnd()
            _ = try? stderr.fileHandleForReading.readToEnd()
        }

        let timedOut = ContinuousClock.now >= deadline
        return DockerResult(
            exitCode: process.terminationStatus,
            stdout: capture.stdout,
            stderr: capture.stderr,
            timedOut: timedOut || capture.isCapped,
            oom: false
        )
    }

    public func kill(containerName: String) async {
        Self.killSync(dockerPath: dockerPath, name: containerName)
    }

    public func removeAll(prefix: String) async {
        guard let listed = try? Self.runDocker(path: dockerPath, arguments: [
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
            _ = try? Self.runDocker(path: dockerPath, arguments: ["rm", "-f", name])
        }
    }

    public func ensureEgressNetwork(name: String = DockerRunner.egressNetwork) throws {
        let inspect = try Self.runDocker(path: dockerPath, arguments: ["network", "inspect", name])
        if inspect.exitCode == 0 { return }
        let created = try Self.runDocker(path: dockerPath, arguments: ["network", "create", name])
        if created.exitCode == 0 { return }
        let again = try Self.runDocker(path: dockerPath, arguments: ["network", "inspect", name])
        if again.exitCode == 0 { return }
        let detail = String(data: created.stderr, encoding: .utf8) ?? "docker network create failed"
        throw DockerRunnerError.networkCreateFailed(detail)
    }

    public static func chownWorkspace(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/chown")
        process.arguments = ["-R", "1000:1000", url.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            #if os(Linux)
            throw error
            #else
            return
            #endif
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            #if os(Linux)
            throw POSIXError(.EPERM)
            #endif
        }
    }

    public static func allocateLoopbackPort() throws -> LoopbackPortLease {
        try LoopbackPortLease.acquire()
    }

    private static func killSync(dockerPath: String, name: String) {
        _ = try? runDocker(path: dockerPath, arguments: ["kill", name])
        _ = try? runDocker(path: dockerPath, arguments: ["rm", "-f", name])
    }

    static func runDocker(path: String, arguments: [String]) throws -> DockerResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
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

public final class LoopbackPortLease: @unchecked Sendable {
    public let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    public static func acquire() throws -> LoopbackPortLease {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EPERM) }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw POSIXError(.EPERM)
        }
        return LoopbackPortLease(port: Int(UInt16(bigEndian: addr.sin_port)), fd: fd)
    }

    private init(port: Int, fd: Int32) {
        self.port = port
        self.fd = fd
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        close(fd)
    }

    deinit {
        release()
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

private final class CaptureBox: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private let limit: Int
    private var out = Data()
    private var err = Data()
    private var capped = false

    init(limit: Int) {
        self.limit = limit
    }

    var stdout: Data {
        lock.lock()
        defer { lock.unlock() }
        return out
    }

    var stderr: Data {
        lock.lock()
        defer { lock.unlock() }
        return err
    }

    var isCapped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capped
    }

    func append(_ data: Data, stream: Stream) -> Bool {
        guard !data.isEmpty else { return true }
        lock.lock()
        defer { lock.unlock() }
        if capped { return false }
        let used = out.count + err.count
        if used >= limit {
            capped = true
            return false
        }
        let room = limit - used
        let chunk = data.prefix(room)
        switch stream {
        case .stdout: out.append(chunk)
        case .stderr: err.append(chunk)
        }
        if out.count + err.count >= limit || chunk.count < data.count {
            capped = true
            return false
        }
        return true
    }
}
