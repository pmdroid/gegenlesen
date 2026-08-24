import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct PackRepoTests {
    @Test
    func packerNeverUsesDotDotBundleRange() throws {
        let source = try String(
            contentsOf: repoRootFromTests().appendingPathComponent("Sources/GegenlesenCore/Git/RepoPacker.swift"),
            encoding: .utf8
        )
        #expect(source.contains("bundle"))
        #expect(source.contains("\"bundle\", \"create\""))
        #expect(!source.contains("$BASE..$HEAD"))
        #expect(!source.contains("BASE..HEAD"))
        #expect(source.contains("diff.patch"))
    }

    @Test
    func packsTinyRepoWithEmbeddedDiff() throws {
        try withTempDir("gegenlesen-pack-tiny") { dir in
            let repo = dir.appendingPathComponent("tiny-repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("README.md", "v1\n", in: repo)
            try git(["add", "README.md"], cwd: repo)
            try git(["commit", "-m", "v1"], cwd: repo)
            try writeFile("README.md", "v2\n", in: repo)
            try git(["add", "README.md"], cwd: repo)
            try git(["commit", "-m", "v2"], cwd: repo)

            let head = try RepoPacker.resolveHead(cwd: repo)
            let base = try RepoPacker.resolveBase(cwd: repo, ref: "HEAD^")
            let packed = try RepoPacker.pack(cwd: repo, base: base, head: head)
            #expect(packed.head == head)
            #expect(packed.base == base)
            #expect(!packed.droppedBundle)

            let archive = dir.appendingPathComponent("tiny.tar.gz")
            try packed.archive.write(to: archive)
            let workspace = dir.appendingPathComponent("ws")
            try ArchiveUnpacker().unpack(archive: archive, into: workspace)
            #expect(
                FileManager.default.fileExists(
                    atPath: workspace.appendingPathComponent(".gegenlesen/diff.patch").path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: workspace.appendingPathComponent(".gegenlesen/history.bundle").path
                )
            )
            #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path))
            let diff = try String(
                contentsOf: workspace.appendingPathComponent(".gegenlesen/diff.patch"),
                encoding: .utf8
            )
            #expect(diff.contains("README.md"))

            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            let changeSet = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: JobID("job-tiny")
            ).identify()
            #expect(changeSet.source == .embeddedDiff)
            #expect(changeSet.files.contains { $0.path == "README.md" })
        }
    }

    @Test
    func sameBaseAndHeadAllowsEmptyDiff() throws {
        try withTempDir("gegenlesen-pack-empty") { dir in
            let repo = dir.appendingPathComponent("tiny-repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("README.md", "v1\n", in: repo)
            try git(["add", "README.md"], cwd: repo)
            try git(["commit", "-m", "v1"], cwd: repo)

            let head = try RepoPacker.resolveHead(cwd: repo)
            let packed = try RepoPacker.pack(cwd: repo, base: head, head: head)
            #expect(packed.base == packed.head)
        }
    }

    @Test
    func dropsOversizedBundle() throws {
        try withTempDir("gegenlesen-pack-bundle-cap") { dir in
            let repo = dir.appendingPathComponent("tiny-repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("README.md", "v1\n", in: repo)
            try git(["add", "README.md"], cwd: repo)
            try git(["commit", "-m", "v1"], cwd: repo)
            try writeFile("README.md", "v2\n", in: repo)
            try git(["add", "README.md"], cwd: repo)
            try git(["commit", "-m", "v2"], cwd: repo)

            let head = try RepoPacker.resolveHead(cwd: repo)
            let base = try RepoPacker.resolveBase(cwd: repo, ref: "HEAD^")
            let packed = try RepoPacker.pack(cwd: repo, base: base, head: head, maxBundleBytes: 1)
            #expect(packed.droppedBundle)

            let archive = dir.appendingPathComponent("tiny.tar.gz")
            try packed.archive.write(to: archive)
            let workspace = dir.appendingPathComponent("ws")
            try ArchiveUnpacker().unpack(archive: archive, into: workspace)
            #expect(
                !FileManager.default.fileExists(
                    atPath: workspace.appendingPathComponent(".gegenlesen/history.bundle").path
                )
            )
        }
    }
}
