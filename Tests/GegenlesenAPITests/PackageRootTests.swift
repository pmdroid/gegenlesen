import Foundation
import Testing
@testable import GegenlesenAPI

@Suite
struct PackageRootTests {
    @Test
    func environmentOverrideWins() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gegenlesen-root-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let resolved = gegenlesenPackageRoot(
            environment: ["GEGENLESEN_ROOT": root.path],
            fileManager: fm,
            cwd: "/tmp",
            executablePath: "/usr/bin/true"
        )
        #expect(resolved == root.path + "/")
    }

    @Test
    func findsLayoutNextToExecutable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gegenlesen-exe-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let dist = root.appendingPathComponent("frontend/dist")
        try fm.createDirectory(at: dist, withIntermediateDirectories: true)
        try "ok".write(to: dist.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let exe = root.appendingPathComponent("GegenlesenAPI")
        try Data().write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        let resolved = gegenlesenPackageRoot(
            environment: [:],
            fileManager: fm,
            cwd: "/tmp",
            executablePath: exe.path
        )
        #expect(resolved == root.path + "/")
    }
}
