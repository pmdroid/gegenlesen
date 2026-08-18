import Foundation
import Testing
@testable import MeisterCore

@Suite
struct FindingMatcherTests {
    @Test
    func normalizeWhitespaceIsNFCTrimAndCollapse() {
        let decomposed = "e\u{0301}"
        let composed = "é"
        #expect(Normalize.whitespace("  \(decomposed)\t\n\(decomposed)  ") == "\(composed) \(composed)")
        #expect(Normalize.whitespace("a\u{00A0}\u{00A0}b\r\nc") == "a b c")
        #expect(Normalize.whitespace("\n\t  trimmed  \r") == "trimmed")
    }

    @Test
    func fingerprintIncludesPathAndEmptyRuleID() {
        let left = Fingerprint.sha256(ruleID: nil, path: "a.swift", snippet: "  x\n")
        let right = Fingerprint.sha256(ruleID: nil, path: "b.swift", snippet: "x")
        let same = Fingerprint.sha256(ruleID: nil, path: "a.swift", snippet: "x")
        #expect(left != right)
        #expect(left == same)
        #expect(left == ContentHash.sha256(Data("\na.swift\nx".utf8)))
    }

    @Test
    func sameSHAAndSameLinesIsStillOpen() throws {
        try withTempDir("matcher-still") { dir in
            let contents = "one\nSNIP\nthree\n"
            try writeFile("src/a.swift", contents, in: dir)
            let sha = ContentHash.sha256(Data(contents.utf8))
            let jobID = JobID.generate()
            let parent = finding(path: "src/a.swift", start: 2, end: 2, snippet: "SNIP")
            let parentFiles = [JobFile(jobID: parent.jobID, path: "src/a.swift", sha256: sha, status: .modified)]
            let child = ChangeSet(
                baseSHA: "a",
                headSHA: "b",
                patchRelativePath: "",
                files: [],
                source: .hashInterdiff
            )
            let carried = FindingMatcher(jobID: jobID).carryForward(
                parent: [parent],
                parentFiles: parentFiles,
                child: child,
                workspace: Workspace(root: dir)
            )
            #expect(carried.count == 1)
            #expect(carried[0].lifecycle == .stillOpen)
            #expect(carried[0].parentFindingID == parent.id)
            #expect(carried[0].startLine == 2)
            #expect(carried[0].jobID == jobID)
        }
    }

    @Test
    func oneHitAtNewLinesIsRelocated() throws {
        try withTempDir("matcher-reloc") { dir in
            let old = "SNIP\nrest\n"
            let next = "lead\nlead\nSNIP\n"
            try writeFile("src/a.swift", next, in: dir)
            let jobID = JobID.generate()
            let parent = finding(path: "src/a.swift", start: 1, end: 1, snippet: "SNIP")
            let parentFiles = [
                JobFile(
                    jobID: parent.jobID,
                    path: "src/a.swift",
                    sha256: ContentHash.sha256(Data(old.utf8)),
                    status: .modified
                ),
            ]
            let child = ChangeSet(
                baseSHA: "a",
                headSHA: "b",
                patchRelativePath: "",
                files: [
                    JobFile(
                        jobID: jobID,
                        path: "src/a.swift",
                        sha256: ContentHash.sha256(Data(next.utf8)),
                        status: .modified
                    ),
                ],
                source: .hashInterdiff
            )
            let carried = FindingMatcher(jobID: jobID).carryForward(
                parent: [parent],
                parentFiles: parentFiles,
                child: child,
                workspace: Workspace(root: dir)
            )
            #expect(carried.count == 1)
            #expect(carried[0].lifecycle == .relocated)
            #expect(carried[0].startLine == 3)
            #expect(carried[0].endLine == 3)
            #expect(carried[0].judgeVerdict == parent.judgeVerdict)
        }
    }

    @Test
    func zeroHitsIsResolved() throws {
        try withTempDir("matcher-res") { dir in
            try writeFile("src/a.swift", "clean\n", in: dir)
            let jobID = JobID.generate()
            let parent = finding(path: "src/a.swift", start: 1, end: 1, snippet: "SNIP")
            let parentFiles = [
                JobFile(jobID: parent.jobID, path: "src/a.swift", sha256: "aa", status: .modified),
            ]
            let child = ChangeSet(
                baseSHA: "a",
                headSHA: "b",
                patchRelativePath: "",
                files: [JobFile(jobID: jobID, path: "src/a.swift", sha256: "bb", status: .modified)],
                source: .hashInterdiff
            )
            let carried = FindingMatcher(jobID: jobID).carryForward(
                parent: [parent],
                parentFiles: parentFiles,
                child: child,
                workspace: Workspace(root: dir)
            )
            #expect(carried.map(\.lifecycle) == [.resolved])
        }
    }

    @Test
    func twoHitsDoesNotCarry() throws {
        try withTempDir("matcher-two") { dir in
            try writeFile("src/a.swift", "SNIP\nmid\nSNIP\n", in: dir)
            let jobID = JobID.generate()
            let parent = finding(path: "src/a.swift", start: 1, end: 1, snippet: "SNIP")
            let parentFiles = [
                JobFile(jobID: parent.jobID, path: "src/a.swift", sha256: "old", status: .modified),
            ]
            let child = ChangeSet(
                baseSHA: "a",
                headSHA: "b",
                patchRelativePath: "",
                files: [JobFile(jobID: jobID, path: "src/a.swift", sha256: "new", status: .modified)],
                source: .hashInterdiff
            )
            let carried = FindingMatcher(jobID: jobID).carryForward(
                parent: [parent],
                parentFiles: parentFiles,
                child: child,
                workspace: Workspace(root: dir)
            )
            #expect(carried.isEmpty)
        }
    }

    @Test
    func collapseAgainstOldPath() {
        let parent = finding(path: "a.swift", start: 1, end: 1, snippet: "SNIP")
        var child = finding(path: "b.swift", start: 4, end: 4, snippet: "SNIP")
        child.jobID = JobID.generate()
        child.id = FindingID.generate()
        let files = [
            JobFile(jobID: child.jobID, path: "b.swift", status: .renamed, oldPath: "a.swift"),
        ]
        let collapsed = FindingMatcher(jobID: child.jobID).collapse(
            child: child,
            parents: [parent],
            childFiles: files
        )
        #expect(collapsed?.lifecycle == .stillOpen)
        #expect(collapsed?.parentFindingID == parent.id)
    }

    @Test
    func collapseRequiresTitleMessageAndRule() {
        let parent = finding(path: "a.swift", start: 1, end: 1, snippet: "SNIP")
        var child = finding(path: "a.swift", start: 1, end: 1, snippet: "SNIP")
        child.title = "other"
        child.id = FindingID.generate()
        let collapsed = FindingMatcher(jobID: child.jobID).collapse(
            child: child,
            parents: [parent],
            childFiles: [JobFile(jobID: child.jobID, path: "a.swift", status: .modified)]
        )
        #expect(collapsed == nil)
    }
}

private func finding(path: String, start: Int, end: Int, snippet: String) -> Finding {
    Finding(
        id: FindingID.generate(),
        jobID: JobID.generate(),
        ruleID: RuleID("use-project-logger"),
        phase: .agent,
        severity: .warning,
        title: "Use the project logger",
        message: "print is never OK",
        filePath: path,
        startLine: start,
        endLine: end,
        snippet: snippet,
        judgeVerdict: .keep,
        lifecycle: .new,
        createdAt: Date()
    )
}
