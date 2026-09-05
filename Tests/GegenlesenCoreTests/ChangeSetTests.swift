import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct ChangeSetTests {
    @Test
    func prefersEmbeddedDiffWithoutGit() throws {
        try withTempDir("gegenlesen-id-embedded") { dir in
            let workspace = dir.appendingPathComponent("ws")
            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            try writeFile("src/app.swift", "print(1)\n", in: workspace)
            try writeFile(
                ".gegenlesen/diff.patch",
                """
                diff --git a/src/app.swift b/src/app.swift
                new file mode 100644
                --- /dev/null
                +++ b/src/app.swift
                @@ -0,0 +1 @@
                +print(1)
                """,
                in: workspace
            )
            try writeFile(".gegenlesen/base_sha", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", in: workspace)
            try writeFile(".gegenlesen/head_sha", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", in: workspace)

            let changeSet = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: JobID("job-embed")
            ).identify()

            #expect(changeSet.source == .embeddedDiff)
            #expect(changeSet.baseSHA == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
            #expect(changeSet.headSHA == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
            #expect(changeSet.files.count == 1)
            #expect(changeSet.files[0].path == "src/app.swift")
            #expect(changeSet.files[0].status == .added)
            #expect(changeSet.files[0].language == .swift)
            #expect(changeSet.files[0].sha256 == ContentHash.sha256(Data("print(1)\n".utf8)))
            #expect(FileManager.default.fileExists(atPath: blobs.patchURL(jobID: "job-embed").path))
            #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path))
        }
    }

    @Test
    func identifiesFromGitWorkingTree() throws {
        try withTempDir("gegenlesen-id-git") { dir in
            let repo = dir.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("a.txt", "one\n", in: repo)
            try git(["add", "a.txt"], cwd: repo)
            try git(["commit", "-m", "one"], cwd: repo)
            try git(["checkout", "-b", "feature"], cwd: repo)
            try writeFile("a.txt", "two\n", in: repo)
            try git(["add", "a.txt"], cwd: repo)
            try git(["commit", "-m", "two"], cwd: repo)

            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            let changeSet = try ChangeSetIdentifier(
                workspace: repo,
                blobs: blobs,
                jobID: JobID("job-git")
            ).identify()

            #expect(changeSet.source == .git)
            #expect(changeSet.files.contains { $0.path == "a.txt" && $0.status == .modified })
            #expect(changeSet.files.first?.sha256 == ContentHash.sha256(Data("two\n".utf8)))
            #expect(changeSet.baseSHA.count == 40)
            #expect(changeSet.headSHA.count == 40)
        }
    }

    @Test
    func fetchesBundleInsteadOfUnbundle() throws {
        try withTempDir("gegenlesen-id-bundle") { dir in
            let repo = dir.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("f.swift", "a\n", in: repo)
            try git(["add", "f.swift"], cwd: repo)
            try git(["commit", "-m", "base"], cwd: repo)
            let base = try gitRevParse("HEAD", cwd: repo)
            try writeFile("f.swift", "b\n", in: repo)
            try git(["add", "f.swift"], cwd: repo)
            try git(["commit", "-m", "head"], cwd: repo)
            let head = try gitRevParse("HEAD", cwd: repo)
            try git(["tag", "gegenlesen-base", base], cwd: repo)
            try git(["tag", "gegenlesen-head", head], cwd: repo)
            let bundle = repo.appendingPathComponent("history.bundle")
            try git(["bundle", "create", bundle.path, "gegenlesen-base", "gegenlesen-head"], cwd: repo)

            let workspace = dir.appendingPathComponent("ws")
            try writeFile("f.swift", "b\n", in: workspace)
            try FileManager.default.createDirectory(
                at: workspace.appendingPathComponent(".gegenlesen"),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: bundle,
                to: workspace.appendingPathComponent(".gegenlesen/history.bundle")
            )
            try writeFile(".gegenlesen/base_sha", base, in: workspace)
            try writeFile(".gegenlesen/head_sha", head, in: workspace)

            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            let changeSet = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: JobID("job-bundle")
            ).identify()

            #expect(changeSet.source == .bundle)
            #expect(changeSet.baseSHA == base)
            #expect(changeSet.headSHA == head)
            #expect(changeSet.files.contains { $0.path == "f.swift" && $0.status == .modified })

            let refs = workspace.appendingPathComponent(".git/refs/bundle")
            #expect(FileManager.default.fileExists(atPath: refs.path))
            #expect(!unbundleWasUsed(in: workspace))
        }
    }

    @Test
    func failsWithNoChangeSetWhenNothingIdentifies() throws {
        try withTempDir("gegenlesen-id-none") { dir in
            let workspace = dir.appendingPathComponent("ws")
            try writeFile("only.txt", "x\n", in: workspace)
            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            #expect(throws: IdentifyError.noChangeSet) {
                try ChangeSetIdentifier(
                    workspace: workspace,
                    blobs: blobs,
                    jobID: JobID("job-none")
                ).identify()
            }
        }
    }

    @Test
    func gitfileIsNotInPlaceHistory() throws {
        try withTempDir("gegenlesen-id-gitfile") { dir in
            let host = dir.appendingPathComponent("host")
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
            try git(["init"], cwd: host)
            try writeFile("secret.swift", "leaked\n", in: host)
            try git(["add", "secret.swift"], cwd: host)
            try git(["commit", "-m", "host"], cwd: host)

            let workspace = dir.appendingPathComponent("ws")
            try writeFile("only.txt", "x\n", in: workspace)
            try writeFile(".git", "gitdir: \(host.path)\n", in: workspace)

            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            #expect(throws: IdentifyError.noChangeSet) {
                try ChangeSetIdentifier(
                    workspace: workspace,
                    blobs: blobs,
                    jobID: JobID("job-gitfile")
                ).identify()
            }
        }
    }

    @Test
    func enrichIgnoresPathsOutsideWorkspace() throws {
        try withTempDir("gegenlesen-id-escape") { dir in
            let secret = dir.appendingPathComponent("secret.txt")
            try "outside-secret\n".write(to: secret, atomically: true, encoding: .utf8)
            let workspace = dir.appendingPathComponent("ws")
            try writeFile(
                ".gegenlesen/diff.patch",
                """
                diff --git a/../secret.txt b/../secret.txt
                new file mode 100644
                --- /dev/null
                +++ b/../secret.txt
                @@ -0,0 +1 @@
                +outside-secret
                """,
                in: workspace
            )
            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            let changeSet = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: JobID("job-escape")
            ).identify()
            #expect(changeSet.source == .embeddedDiff)
            #expect(changeSet.files.allSatisfy { $0.sha256 == nil })
        }
    }

    @Test
    func appliesMultipartUnifiedDiff() throws {
        try withTempDir("gegenlesen-id-multi") { dir in
            let workspace = dir.appendingPathComponent("ws")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let patch = Data(
                """
                diff --git a/new.txt b/new.txt
                new file mode 100644
                index 0000000..ce01362
                --- /dev/null
                +++ b/new.txt
                @@ -0,0 +1 @@
                +hello

                """.utf8
            )
            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            let changeSet = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: JobID("job-multi"),
                multipartPatch: patch
            ).identify()
            #expect(changeSet.source == .multipartPatch)
            #expect(changeSet.baseSHA == "noparent")
            #expect(changeSet.headSHA == ContentHash.sha256(patch))
            #expect(try String(contentsOf: workspace.appendingPathComponent("new.txt")) == "hello\n")
        }
    }
    @Test
    func staleOriginMainResolvesToFreshBaseAfterFetch() throws {
        try withTempDir("gegenlesen-id-stale-origin") { dir in
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
            let freshMain = try gitRevParse("main", cwd: origin)

            // Branch the feature on the new main, then rewind the clone's
            // remote-tracking ref to simulate a stale worktree.
            try git(["fetch", "origin"], cwd: work)
            try git(["checkout", "-b", "feature", "origin/main"], cwd: work)
            try writeFile("f2.txt", "two\n", in: work)
            try git(["add", "f2.txt"], cwd: work)
            try git(["commit", "-m", "c2"], cwd: work)
            let stale = try gitRevParse("main", cwd: work)
            try git(["update-ref", "refs/remotes/origin/main", stale], cwd: work)

            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            let changeSet = try ChangeSetIdentifier(
                workspace: work,
                blobs: blobs,
                jobID: JobID("job-stale")
            ).identify()

            #expect(changeSet.baseSHA == freshMain)
            #expect(changeSet.baseSource == "merge_base:origin/main")
            #expect(changeSet.files.contains { $0.path == "f2.txt" && $0.status == .added })
            #expect(!changeSet.files.contains { $0.path == "f1.txt" })
        }
    }

    @Test
    func explicitBaseRefWinsOverGuess() throws {
        try withTempDir("gegenlesen-id-base-ref") { dir in
            let repo = dir.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("f0.txt", "zero\n", in: repo)
            try git(["add", "f0.txt"], cwd: repo)
            try git(["commit", "-m", "c0"], cwd: repo)
            try git(["branch", "release-1"], cwd: repo)
            let releaseOne = try gitRevParse("release-1", cwd: repo)
            try writeFile("f1.txt", "one\n", in: repo)
            try git(["add", "f1.txt"], cwd: repo)
            try git(["commit", "-m", "c1"], cwd: repo)
            try git(["checkout", "-b", "feature"], cwd: repo)
            try writeFile("f2.txt", "two\n", in: repo)
            try git(["add", "f2.txt"], cwd: repo)
            try git(["commit", "-m", "c2"], cwd: repo)

            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            let changeSet = try ChangeSetIdentifier(
                workspace: repo,
                blobs: blobs,
                jobID: JobID("job-base-ref"),
                meta: IdentifyMeta(baseRef: "release-1")
            ).identify()

            #expect(changeSet.baseSHA == releaseOne)
            #expect(changeSet.baseSource == "base_ref:release-1")
            #expect(changeSet.files.contains { $0.path == "f1.txt" })
        }
    }

    @Test
    func widePackSignalFiresForGuessedAncientBase() throws {
        #expect(PackSignals.isWide(packFiles: 292, headOwnFiles: 2))
        #expect(PackSignals.isWide(packFiles: 30, headOwnFiles: 2))
        #expect(!PackSignals.isWide(packFiles: 20, headOwnFiles: 2))
        #expect(!PackSignals.isWide(packFiles: 2, headOwnFiles: 2))
        #expect(!PackSignals.isWide(packFiles: 292, headOwnFiles: nil))

        try withTempDir("gegenlesen-id-wide-pack") { dir in
            let repo = dir.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("f0.txt", "zero\n", in: repo)
            try git(["add", "f0.txt"], cwd: repo)
            try git(["commit", "-m", "c0"], cwd: repo)
            let base = try gitRevParse("main", cwd: repo)
            try writeFile("f1.txt", "one\n", in: repo)
            try git(["add", "f1.txt"], cwd: repo)
            try git(["commit", "-m", "c1"], cwd: repo)
            let head = try gitRevParse("main", cwd: repo)

            let jobID = JobID("job-wide")
            let wide = ChangeSet(
                baseSHA: base,
                headSHA: head,
                patchRelativePath: "blobs/patches/\(jobID.rawValue).patch",
                files: (0..<40).map { index in
                    JobFile(jobID: jobID, path: "f\(index).txt", status: .added, language: .other)
                },
                source: .git,
                baseSource: "merge_base:origin/main"
            )
            let signal = try #require(PackSignals.evaluate(changeSet: wide, workspace: repo, timeout: .seconds(30)))
            #expect(signal.packFiles == 40)
            #expect(signal.headOwnFiles == 1)
            #expect(signal.base == base)
            #expect(signal.baseSource == "merge_base:origin/main")

            let narrow = ChangeSet(
                baseSHA: base,
                headSHA: head,
                patchRelativePath: "blobs/patches/\(jobID.rawValue).patch",
                files: [
                    JobFile(jobID: jobID, path: "f1.txt", status: .added, language: .other),
                ],
                source: .git
            )
            #expect(PackSignals.evaluate(changeSet: narrow, workspace: repo, timeout: .seconds(30)) == nil)
        }
    }
}

private func gitRevParse(_ rev: String, cwd: URL) throws -> String {
    let result = try runIsolated(
        executable: "/usr/bin/git",
        arguments: ["rev-parse", rev],
        cwd: cwd
    )
    return String(data: result.stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func unbundleWasUsed(in workspace: URL) -> Bool {
    let config = workspace.appendingPathComponent(".git")
    guard let enumerator = FileManager.default.enumerator(at: config, includingPropertiesForKeys: nil) else {
        return false
    }
    for case let url as URL in enumerator {
        if url.lastPathComponent.contains("unbundle") {
            return true
        }
    }
    return false
}
