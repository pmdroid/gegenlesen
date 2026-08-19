import Foundation

enum EvalPacker {
    static func pack(head: URL, base: URL?, packScript: URL) throws -> URL {
        try withTempDir("eval-pack") { repo in
            try git(["init", "-b", "main"], cwd: repo)
            if let base, FileManager.default.fileExists(atPath: base.path) {
                try copyContents(of: base, into: repo)
            }
            try git(["add", "-A"], cwd: repo)
            try git(["commit", "--allow-empty", "-m", "base"], cwd: repo)
            try replaceWorkingTree(root: repo, with: head)
            try git(["add", "-A"], cwd: repo)
            try git(["commit", "-m", "head"], cwd: repo)
            let archive = FileManager.default.temporaryDirectory
                .appendingPathComponent("eval-\(UUID().uuidString).tar.gz")
            try runPack(script: packScript, cwd: repo, output: archive)
            return archive
        }
    }

    private static func replaceWorkingTree(root: URL, with source: URL) throws {
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if item.lastPathComponent == ".git" { continue }
            try fm.removeItem(at: item)
        }
        try copyContents(of: source, into: root)
    }

    private static func copyContents(of source: URL, into destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.copyItem(at: item, to: target)
        }
    }

    private static func withTempDir<T>(_ prefix: String, _ body: (URL) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    private static func git(_ arguments: [String], cwd: URL) throws {
        let result = try run(
            executable: "/usr/bin/git",
            arguments: [
                "-c", "user.name=gegenlesen",
                "-c", "user.email=gegenlesen@localhost",
                "-c", "init.defaultBranch=main",
                "-c", "safe.directory=*",
            ] + arguments,
            cwd: cwd
        )
        if result.status != 0 {
            let err = String(data: result.stderr, encoding: .utf8) ?? ""
            throw EvalError(err.isEmpty ? "git \(arguments.first ?? "") failed" : err)
        }
    }

    private static func runPack(script: URL, cwd: URL, output: URL) throws {
        let result = try run(
            executable: "/bin/sh",
            arguments: [script.path, "HEAD^"],
            cwd: cwd
        )
        if result.status != 0 {
            let err = String(data: result.stderr, encoding: .utf8) ?? ""
            throw EvalError(err.isEmpty ? "pack-repo.sh failed" : err)
        }
        try result.stdout.write(to: output)
    }

    private static func run(
        executable: String,
        arguments: [String],
        cwd: URL
    ) throws -> (stdout: Data, stderr: Data, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var env = GitRunner.isolatedEnvironment(home: cwd.appendingPathComponent(".home").path)
        env["COPYFILE_DISABLE"] = "1"
        env["PATH"] = "/usr/bin:/bin:/usr/local/bin"
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
}
