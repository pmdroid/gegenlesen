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
