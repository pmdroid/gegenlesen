import Foundation
import Testing
@testable import MeisterCore

@Suite
struct IncrementalDiffTests {
    @Test
    func hashInterdiffEmptyWhenSHAsMatch() throws {
        try withTempDir("inc-empty") { dir in
            let workspace = dir.appendingPathComponent("ws")
            try writeFile("Sources/A.swift", "print(2)\n", in: workspace)
            try writeFile(
                ".meister/diff.patch",
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
                ".meister/diff.patch",
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
