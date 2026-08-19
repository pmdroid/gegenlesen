import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct IncrementalDiffTests {
    @Test
    func hashInterdiffEmptyWhenSHAsMatch() throws {
        try withTempDir("inc-empty") { dir in
            let workspace = dir.appendingPathComponent("ws")
            try writeFile("Sources/A.swift", "print(2)\n", in: workspace)
            try writeFile(
                ".gegenlesen/diff.patch",
                """
                diff --git a/Sources/A.swift b/Sources/A.swift
                new file mode 100644
                --- /dev/null
                +++ b/Sources/A.swift
                @@ -0,0 +1 @@
                +print(2)
                """,
                in: workspace
            )
            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            try blobs.ensureLayout()
            let jobID = JobID.generate()
            let identified = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: jobID
            ).identify()
            let sha = ContentHash.sha256(Data("print(2)\n".utf8))
            let parentFiles = [
                JobFile(jobID: JobID.generate(), path: "Sources/A.swift", sha256: sha, status: .added),
            ]
            let interdiff = try IncrementalDiff.compute(
                identified: identified,
                workspace: workspace,
                blobs: blobs,
                jobID: jobID,
                parentHeadSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                parentFiles: parentFiles,
                parentWorkspace: nil,
                timeout: .seconds(10)
            )
            #expect(interdiff.files.isEmpty)
            #expect(interdiff.source == .hashInterdiff)
        }
    }

    @Test
    func missingParentWorkspaceTreatsChangedFileAsAddedPatch() throws {
        try withTempDir("inc-gone") { dir in
            let workspace = dir.appendingPathComponent("ws")
            try writeFile("Sources/A.swift", "print(3)\n", in: workspace)
            try writeFile(
                ".gegenlesen/diff.patch",
                """
                diff --git a/Sources/A.swift b/Sources/A.swift
                --- a/Sources/A.swift
                +++ b/Sources/A.swift
                @@ -1 +1 @@
                -print(2)
                +print(3)
                """,
                in: workspace
            )
            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            try blobs.ensureLayout()
            let jobID = JobID.generate()
            let identified = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: jobID
            ).identify()
            let parentFiles = [
                JobFile(
                    jobID: JobID.generate(),
                    path: "Sources/A.swift",
                    sha256: ContentHash.sha256(Data("print(2)\n".utf8)),
                    status: .modified
                ),
            ]
            let interdiff = try IncrementalDiff.compute(
                identified: identified,
                workspace: workspace,
                blobs: blobs,
                jobID: jobID,
                parentHeadSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                parentFiles: parentFiles,
                parentWorkspace: nil,
                timeout: .seconds(10)
            )
            #expect(interdiff.files.contains { $0.path == "Sources/A.swift" && $0.status == .modified })
            let patch = try String(contentsOf: blobs.patchURL(jobID: jobID.rawValue), encoding: .utf8)
            #expect(patch.contains("--- /dev/null"))
        }
    }

    @Test
    func gitInterdiffWhenParentHeadExists() throws {
        try withTempDir("inc-git") { dir in
            let repo = dir.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("a.txt", "one\n", in: repo)
            try git(["add", "a.txt"], cwd: repo)
            try git(["commit", "-m", "one"], cwd: repo)
            let parentHead = try revParse(repo)
            try writeFile("a.txt", "two\n", in: repo)
            try git(["add", "a.txt"], cwd: repo)
            try git(["commit", "-m", "two"], cwd: repo)

            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            try blobs.ensureLayout()
            let jobID = JobID.generate()
            let identified = try ChangeSetIdentifier(
                workspace: repo,
                blobs: blobs,
                jobID: jobID
            ).identify()
            let interdiff = try IncrementalDiff.compute(
                identified: identified,
                workspace: repo,
                blobs: blobs,
                jobID: jobID,
                parentHeadSHA: parentHead,
                parentFiles: [
                    JobFile(
                        jobID: JobID.generate(),
                        path: "a.txt",
                        sha256: ContentHash.sha256(Data("one\n".utf8)),
                        status: .added
                    ),
                ],
                parentWorkspace: repo,
                timeout: .seconds(10)
            )
            #expect(interdiff.source == .git)
            #expect(interdiff.files.contains { $0.path == "a.txt" && $0.status == .modified })
            #expect(interdiff.baseSHA == parentHead)
            let workspacePatch = try String(
                contentsOf: repo.appendingPathComponent(".gegenlesen/diff.patch"),
                encoding: .utf8
            )
            let blobPatch = try String(contentsOf: blobs.patchURL(jobID: jobID.rawValue), encoding: .utf8)
            #expect(workspacePatch == blobPatch)
        }
    }

    @Test
    func hashInterdiffRenamePlusEditDoesNotAlsoDelete() throws {
        try withTempDir("inc-rename") { dir in
            let workspace = dir.appendingPathComponent("ws")
            try writeFile("b.swift", "print(3)\n", in: workspace)
            try writeFile(
                ".gegenlesen/diff.patch",
                """
                diff --git a/a.swift b/b.swift
                rename from a.swift
                rename to b.swift
                --- a/a.swift
                +++ b/b.swift
                @@ -1 +1 @@
                -print(2)
                +print(3)
                """,
                in: workspace
            )
            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            try blobs.ensureLayout()
            let jobID = JobID.generate()
            let identified = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: jobID
            ).identify()
            #expect(identified.files.contains { $0.path == "b.swift" && $0.oldPath == "a.swift" })
            let parentFiles = [
                JobFile(
                    jobID: JobID.generate(),
                    path: "a.swift",
                    sha256: ContentHash.sha256(Data("print(2)\n".utf8)),
                    status: .added
                ),
            ]
            let interdiff = try IncrementalDiff.compute(
                identified: identified,
                workspace: workspace,
                blobs: blobs,
                jobID: jobID,
                parentHeadSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                parentFiles: parentFiles,
                parentWorkspace: nil,
                timeout: .seconds(10)
            )
            #expect(interdiff.files.contains { $0.path == "b.swift" && $0.status == .renamed && $0.oldPath == "a.swift" })
            #expect(!interdiff.files.contains { $0.path == "a.swift" && $0.status == .deleted })
            #expect(interdiff.files.count == 1)
        }
    }

    @Test
    func overwritesWorkspaceDiffPatchWithInterdiff() throws {
        try withTempDir("inc-overwrite") { dir in
            let workspace = dir.appendingPathComponent("ws")
            let original = """
                diff --git a/Sources/A.swift b/Sources/A.swift
                --- a/Sources/A.swift
                +++ b/Sources/A.swift
                @@ -1 +1 @@
                -print(2)
                +print(3)
                """
            try writeFile("Sources/A.swift", "print(3)\n", in: workspace)
            try writeFile(".gegenlesen/diff.patch", original, in: workspace)
            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            try blobs.ensureLayout()
            let jobID = JobID.generate()
            let identified = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: jobID
            ).identify()
            let interdiff = try IncrementalDiff.compute(
                identified: identified,
                workspace: workspace,
                blobs: blobs,
                jobID: jobID,
                parentHeadSHA: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                parentFiles: [
                    JobFile(
                        jobID: JobID.generate(),
                        path: "Sources/A.swift",
                        sha256: ContentHash.sha256(Data("print(2)\n".utf8)),
                        status: .modified
                    ),
                ],
                parentWorkspace: nil,
                timeout: .seconds(10)
            )
            #expect(!interdiff.files.isEmpty)
            let workspacePatch = try String(
                contentsOf: workspace.appendingPathComponent(".gegenlesen/diff.patch"),
                encoding: .utf8
            )
            let blobPatch = try String(contentsOf: blobs.patchURL(jobID: jobID.rawValue), encoding: .utf8)
            #expect(workspacePatch == blobPatch)
            #expect(workspacePatch != original)
            #expect(workspacePatch.contains("--- /dev/null"))
        }
    }

    @Test
    func fetchesBundleThenGitInterdiffs() throws {
        try withTempDir("inc-bundle") { dir in
            let repo = dir.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("f.swift", "a\n", in: repo)
            try git(["add", "f.swift"], cwd: repo)
            try git(["commit", "-m", "base"], cwd: repo)
            let parentHead = try revParse(repo)
            try writeFile("f.swift", "b\n", in: repo)
            try git(["add", "f.swift"], cwd: repo)
            try git(["commit", "-m", "head"], cwd: repo)
            let head = try revParse(repo)
            try git(["tag", "gegenlesen-base", parentHead], cwd: repo)
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
            try writeFile(".gegenlesen/head_sha", head, in: workspace)
            try writeFile(
                ".gegenlesen/diff.patch",
                """
                diff --git a/f.swift b/f.swift
                --- a/f.swift
                +++ b/f.swift
                @@ -1 +1 @@
                -a
                +b
                """,
                in: workspace
            )

            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            try blobs.ensureLayout()
            let jobID = JobID.generate()
            let identified = try ChangeSetIdentifier(
                workspace: workspace,
                blobs: blobs,
                jobID: jobID
            ).identify()
            #expect(identified.source == .embeddedDiff)
            #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path))

            let interdiff = try IncrementalDiff.compute(
                identified: identified,
                workspace: workspace,
                blobs: blobs,
                jobID: jobID,
                parentHeadSHA: parentHead,
                parentFiles: [
                    JobFile(
                        jobID: JobID.generate(),
                        path: "f.swift",
                        sha256: ContentHash.sha256(Data("a\n".utf8)),
                        status: .added
                    ),
                ],
                parentWorkspace: nil,
                timeout: .seconds(10)
            )
            #expect(interdiff.source == .bundle)
            #expect(interdiff.files.contains { $0.path == "f.swift" && $0.status == .modified })
        }
    }

    @Test
    func missingParentObjectFallsBackToHashInterdiff() throws {
        try withTempDir("inc-fallback") { dir in
            let repo = dir.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init"], cwd: repo)
            try writeFile("a.txt", "two\n", in: repo)
            try git(["add", "a.txt"], cwd: repo)
            try git(["commit", "-m", "two"], cwd: repo)
            let blobs = BlobStore(root: dir.appendingPathComponent("var"))
            try blobs.ensureLayout()
            let jobID = JobID.generate()
            let identified = try ChangeSetIdentifier(
                workspace: repo,
                blobs: blobs,
                jobID: jobID
            ).identify()
            let interdiff = try IncrementalDiff.compute(
                identified: identified,
                workspace: repo,
                blobs: blobs,
                jobID: jobID,
                parentHeadSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                parentFiles: [
                    JobFile(
                        jobID: JobID.generate(),
                        path: "a.txt",
                        sha256: ContentHash.sha256(Data("one\n".utf8)),
                        status: .added
                    ),
                ],
                parentWorkspace: nil,
                timeout: .seconds(10)
            )
            #expect(interdiff.source == .hashInterdiff)
            #expect(interdiff.files.contains { $0.path == "a.txt" })
        }
    }
}

private func revParse(_ repo: URL) throws -> String {
    let result = try runIsolated(
        executable: "/usr/bin/git",
        arguments: ["rev-parse", "HEAD"],
        cwd: repo
    )
    return String(data: result.stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
