import Foundation
@testable import MeisterCore

func withTempDir(_ prefix: String, _ body: (URL) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir)
}

func runIsolated(
    executable: String,
    arguments: [String],
    cwd: URL,
    extraEnv: [String: String] = [:]
) throws -> (stdout: Data, stderr: Data, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = cwd
    var env = GitRunner.isolatedEnvironment()
    env["PATH"] = "/usr/bin:/bin"
    env["HOME"] = cwd.appendingPathComponent(".home").path
    env["COPYFILE_DISABLE"] = "1"
    extraEnv.forEach { env[$0.key] = $0.value }
    process.environment = env
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return (
        stdout.fileHandleForReading.readDataToEndOfFile(),
        stderr.fileHandleForReading.readDataToEndOfFile(),
        process.terminationStatus
    )
}

func git(_ arguments: [String], cwd: URL) throws {
    let result = try runIsolated(executable: "/usr/bin/git", arguments: [
        "-c", "user.name=meister",
        "-c", "user.email=meister@localhost",
        "-c", "init.defaultBranch=main",
        "-c", "safe.directory=*",
    ] + arguments, cwd: cwd)
    if result.status != 0 {
        let err = String(data: result.stderr, encoding: .utf8) ?? ""
        throw IdentifyError(errorMessage: err.isEmpty ? "git \(arguments[0]) failed" : err)
    }
}

func writeFile(_ relative: String, _ contents: String, in root: URL) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
}

func bsdtarCreate(from source: URL, to archive: URL, format: String = "ustar") throws {
    let result = try runIsolated(
        executable: "/usr/bin/bsdtar",
        arguments: ["--format", format, "-cf", archive.path, "-C", source.path, "."],
        cwd: source
    )
    if result.status != 0 {
        let err = String(data: result.stderr, encoding: .utf8) ?? "bsdtar failed"
        throw IdentifyError(errorMessage: err)
    }
}

func gzipTarCreate(from source: URL, to archive: URL) throws {
    let result = try runIsolated(
        executable: "/usr/bin/bsdtar",
        arguments: ["-czf", archive.path, "-C", source.path, "."],
        cwd: source
    )
    if result.status != 0 {
        let err = String(data: result.stderr, encoding: .utf8) ?? "bsdtar failed"
        throw IdentifyError(errorMessage: err)
    }
}

/// USTAR header with declared size; body is omitted so tests can reject on size.
func ustarHeader(
    name: String,
    size: Int,
    typeflag: UInt8 = 0x30,
    linkname: String = ""
) -> Data {
    var block = [UInt8](repeating: 0, count: 512)
    func put(_ string: String, at offset: Int, length: Int) {
        let bytes = Array(string.utf8.prefix(length))
        for index in bytes.indices {
            block[offset + index] = bytes[index]
        }
    }
    put(name, at: 0, length: 100)
    put("0000644", at: 100, length: 8)
    put("0000000", at: 108, length: 8)
    put("0000000", at: 116, length: 8)
    put(String(format: "%011o", size), at: 124, length: 12)
    put("00000000000", at: 136, length: 12)
    put("        ", at: 148, length: 8)
    block[156] = typeflag
    put(linkname, at: 157, length: 100)
    put("ustar", at: 257, length: 6)
    block[263] = 0x30
    block[264] = 0x30
    var sum = 0
    for byte in block {
        sum += Int(byte)
    }
    let checksum = String(format: "%06o", sum)
    put(checksum, at: 148, length: 6)
    block[154] = 0
    block[155] = 0x20
    return Data(block)
}

func ustarArchive(_ members: Data...) -> Data {
    members.reduce(Data(), +) + Data(count: 1024)
}

func gzip(_ data: Data) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    process.environment = ["PATH": "/usr/bin:/bin"]
    try process.run()
    stdin.fileHandleForWriting.write(data)
    try stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw IdentifyError(errorMessage: "gzip failed")
    }
    return stdout.fileHandleForReading.readDataToEndOfFile()
}

func repoRootFromTests() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // MeisterCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo
}
