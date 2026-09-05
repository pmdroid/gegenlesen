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
            let packed = try RepoPacker.pack(
                cwd: repo,
                base: base.sha,
                head: head,
                baseSource: base.source
            )
            #expect(packed.head == head)
            #expect(packed.base == base.sha)
            #expect(packed.baseSource == "explicit_ref:HEAD^")
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
    func resolveBaseFetchesAndPrefersRemoteTracking() throws {
        try withTempDir("gegenlesen-pack-stale-origin") { dir in
            let origin = dir.appendingPathComponent("origin")
            try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
            try git(["init"], cwd: origin)
            try writeFile("f0.txt", "zero\n", in: origin)
            try git(["add", "f0.txt"], cwd: origin)
            try git(["commit", "-m", "c0"], cwd: origin)

            let work = dir.appendingPathComponent("work")
            try git(["clone", origin.path, work.path], cwd: dir)

            // Advance origin/main without the clone knowing about it.
            try writeFile("f1.txt", "one\n", in: origin)
            try git(["add", "f1.txt"], cwd: origin)
            try git(["commit", "-m", "c1"], cwd: origin)

            // Branch the feature on the new origin/main, then rewind the
            // clone's remote-tracking ref to simulate a stale worktree.
            try git(["fetch", "origin"], cwd: work)
            try git(["checkout", "-b", "feature", "origin/main"], cwd: work)
            try writeFile("f2.txt", "two\n", in: work)
            try git(["add", "f2.txt"], cwd: work)
            try git(["commit", "-m", "c2"], cwd: work)
            let stale = try gitOutput(["rev-parse", "main"], cwd: work)
            try git(["update-ref", "refs/remotes/origin/main", stale], cwd: work)

            let resolved = try RepoPacker.resolveBase(cwd: work, ref: nil)
            let fresh = try gitOutput(["rev-parse", "origin/main"], cwd: work)
            #expect(resolved.sha == fresh)
            #expect(resolved.source == "merge_base:origin/main")
        }
    }

    @Test
    func resolveBaseWithoutRemoteStillResolves() throws {
        try withTempDir("gegenlesen-pack-no-remote") { dir in
            let repo = dir.appendingPathComponent("tiny-repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("README.md", "v1\n", in: repo)
            try git(["add", "README.md"], cwd: repo)
            try git(["commit", "-m", "v1"], cwd: repo)
            try writeFile("README.md", "v2\n", in: repo)
            try git(["add", "README.md"], cwd: repo)
            try git(["commit", "-m", "v2"], cwd: repo)

            let explicit = try RepoPacker.resolveBase(cwd: repo, ref: "main")
            #expect(explicit.source == "explicit_ref:main")
            let mainSHA = try gitOutput(["rev-parse", "main"], cwd: repo)
            #expect(explicit.sha == mainSHA)

            let guessed = try RepoPacker.resolveBase(cwd: repo, ref: nil)
            #expect(guessed.source == "merge_base:main")
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
            let packed = try RepoPacker.pack(cwd: repo, base: base.sha, head: head, maxBundleBytes: 1)
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

    /// git helper that returns stdout.
    private func gitOutput(_ arguments: [String], cwd: URL) throws -> String {
        let result = try runIsolated(executable: "/usr/bin/git", arguments: [
            "-c", "safe.directory=*",
        ] + arguments, cwd: cwd)
        #expect(result.status == 0)
        return String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
