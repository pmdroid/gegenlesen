import Foundation
import Testing
@testable import GegenlesenAgent

@Suite
struct DockerRunnerChownTests {
    @Test
    func prefersSbinWhenPresent() throws {
        try withTempDir("chown-sbin") { dir in
            let sbin = dir.appendingPathComponent("sbin-chown")
            let bin = dir.appendingPathComponent("bin-chown")
            try Data().write(to: sbin)
            try Data().write(to: bin)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sbin.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            let path = DockerRunner.chownExecutablePath(
                candidates: [sbin.path, bin.path]
            )
            #expect(path == sbin.path)
        }
    }

    @Test
    func fallsBackToUsrBin() throws {
        try withTempDir("chown-bin") { dir in
            let missing = dir.appendingPathComponent("sbin-chown")
            let bin = dir.appendingPathComponent("bin-chown")
            try Data().write(to: bin)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            let path = DockerRunner.chownExecutablePath(
                candidates: [missing.path, bin.path]
            )
            #expect(path == bin.path)
        }
    }

    @Test
    func nilWhenNeitherExists() {
        let path = DockerRunner.chownExecutablePath(
            candidates: ["/tmp/gegenlesen-no-chown-a", "/tmp/gegenlesen-no-chown-b"]
        )
        #expect(path == nil)
    }
}
