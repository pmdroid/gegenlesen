import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct PackRepoTests {
    @Test
    func scriptNeverUsesDotDotBundleRange() throws {
        let script = try String(
            contentsOf: repoRootFromTests().appendingPathComponent("scripts/pack-repo.sh"),
            encoding: .utf8
        )
        #expect(script.contains("git bundle create"))
        #expect(script.contains("\"$BASE\" \"$HEAD\""))
        #expect(!script.contains("$BASE..$HEAD"))
        #expect(!script.contains("\"$BASE..$HEAD\""))
        #expect(script.contains(".gegenlesen/diff.patch"))
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

            let script = repoRootFromTests().appendingPathComponent("scripts/pack-repo.sh")
            let archive = dir.appendingPathComponent("tiny.tar.gz")
            let packed = try runIsolated(
                executable: "/bin/sh",
                arguments: [script.path, "HEAD^"],
                cwd: repo
            )
            #expect(packed.status == 0)
            try packed.stdout.write(to: archive)

            let workspace = dir.appendingPathComponent("ws")
            try ArchiveUnpacker().unpack(archive: archive, into: workspace)
            #expect(
                FileManager.default.fileExists(
                    atPath: workspace.appendingPathComponent(".gegenlesen/diff.patch").path
                )
            )
            #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path))

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
}
