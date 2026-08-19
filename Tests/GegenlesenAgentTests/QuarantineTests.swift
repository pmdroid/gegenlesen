import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct QuarantineTests {
    @Test
    func copiesAndRenamesLoadableConfigLeavingAgents() throws {
        try withTempDir("quarantine") { root in
            try writeFile("opencode.json", #"{"permission":{"edit":"allow"}}"#, in: root)
            try writeFile("AGENTS.md", "house rule: use OSLog\n", in: root)
            try writeFile("CLAUDE.md", "claude notes\n", in: root)
            try writeFile(".claude/settings.json", "{}\n", in: root)
            try writeFile(".opencode/plugins/pwn.js", "console.log('pwn')\n", in: root)

            try Quarantine.run(workspace: Workspace(root: root))

            let fm = FileManager.default
            #expect(fm.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))
            #expect(fm.fileExists(atPath: root.appendingPathComponent("CLAUDE.md").path))
            #expect(fm.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path))
            #expect(fm.fileExists(atPath: root.appendingPathComponent("opencode.json.gegenlesen-disabled").path))
            #expect(fm.fileExists(atPath: root.appendingPathComponent(".opencode.gegenlesen-disabled/plugins/pwn.js").path))
            #expect(!fm.fileExists(atPath: root.appendingPathComponent("opencode.json").path))
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(".opencode").path))
            #expect(fm.fileExists(atPath: root.appendingPathComponent(".gegenlesen/quarantine/opencode.json").path))
            #expect(fm.fileExists(atPath: root.appendingPathComponent(".gegenlesen/quarantine/AGENTS.md").path))
            #expect(fm.fileExists(atPath: root.appendingPathComponent(".gegenlesen/quarantine/.opencode/plugins/pwn.js").path))
        }
    }

    @Test
    func evilArchiveHasEscalationPayloadAndQuarantineDisablesIt() throws {
        let archive = repoRootFromAgentTests()
            .appendingPathComponent("Tests/Fixtures/evil-opencode-json.tar.gz")
        #expect(FileManager.default.fileExists(atPath: archive.path))

        try withTempDir("evil-unpack") { root in
            try ArchiveUnpacker().unpack(archive: archive, into: root)
            let json = try String(
                contentsOf: root.appendingPathComponent("opencode.json"),
                encoding: .utf8
            )
            #expect(json.contains(#""edit":"allow""#) || json.contains(#""edit": "allow""#))
            #expect(json.contains(#""curl *""#))
            #expect(json.contains("mcp"))
            #expect(FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".opencode/plugins/pwn.js").path
            ))

            try Quarantine.run(workspace: Workspace(root: root))

            let fm = FileManager.default
            #expect(fm.fileExists(atPath: root.appendingPathComponent("opencode.json.gegenlesen-disabled").path))
            #expect(fm.fileExists(atPath: root.appendingPathComponent(".opencode.gegenlesen-disabled").path))
            #expect(!fm.fileExists(atPath: root.appendingPathComponent("opencode.json").path))
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(".opencode").path))
        }
    }

    @Test
    func directorySymlinkIsCopiedNotWalked() throws {
        try withTempDir("quarantine-symlink") { root in
            try writeFile("Sources/A.swift", "ok\n", in: root)
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(".opencode").path,
                withDestinationPath: "."
            )
            try Quarantine.run(workspace: Workspace(root: root))
            let fm = FileManager.default
            #expect(fm.fileExists(atPath: root.appendingPathComponent(".opencode.gegenlesen-disabled").path))
            #expect(!fm.fileExists(atPath: root.appendingPathComponent(".opencode").path))
        }
    }
}
