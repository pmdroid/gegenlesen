import Darwin
import Foundation
import MeisterCore

public actor DockerRunner: DockerExecuting {
    public static let maxCaptureBytes = 20 * 1024 * 1024

    public var dockerPath: String

    public init(dockerPath: String = "/usr/bin/docker") {
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
        if request.injectProviderKeys {
            let host = ProcessInfo.processInfo.environment
            for key in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"] {
                if let value = host[key], !value.isEmpty {
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

        let capture = CaptureBox()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            capture.append(handle.availableData, stream: .stdout)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            capture.append(handle.availableData, stream: .stderr)
        }

        do {
            try process.run()
        } catch {
            return DockerResult(exitCode: 127)
        }

        let deadline = ContinuousClock.now + request.timeout
        let name = request.name
        let watchdog = Task { [dockerPath] in
            try await Task.sleep(until: deadline, clock: .continuous)
            Self.killSync(dockerPath: dockerPath, name: name)
        }

        let sizeWatch = Task { [dockerPath] in
            while !Task.isCancelled {
                if capture.total > Self.maxCaptureBytes {
                    Self.killSync(dockerPath: dockerPath, name: name)
                    process.terminate()
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }
        watchdog.cancel()
        sizeWatch.cancel()

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        capture.append(stdout.fileHandleForReading.readDataToEndOfFile(), stream: .stdout)
        capture.append(stderr.fileHandleForReading.readDataToEndOfFile(), stream: .stderr)

        let timedOut = ContinuousClock.now >= deadline
        let overSize = capture.total > Self.maxCaptureBytes
        return DockerResult(
            exitCode: process.terminationStatus,
            stdout: capture.stdout,
            stderr: capture.stderr,
            timedOut: timedOut || overSize,
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

    public static func allocateLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EPERM) }
        defer { close(fd) }
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
        guard bindResult == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else { throw POSIXError(.EPERM) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func killSync(dockerPath: String, name: String) {
        _ = try? runDocker(path: dockerPath, arguments: ["kill", name])
        _ = try? runDocker(path: dockerPath, arguments: ["rm", "-f", name])
    }

    private static func runDocker(path: String, arguments: [String]) throws -> DockerResult {
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

private final class CaptureBox: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

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

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return out.count + err.count
    }

    func append(_ data: Data, stream: Stream) {
        guard !data.isEmpty else { return }
        lock.lock()
        switch stream {
        case .stdout: out.append(data)
        case .stderr: err.append(data)
        }
        lock.unlock()
    }
}
