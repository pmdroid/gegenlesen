import Foundation
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct FindingsParserTests {
    @Test
    func agentsCitationIsKeptAfterQuarantine() throws {
        try withTempDir("parser-agents") { root in
            try writeFile("AGENTS.md", "Use OSLog, never print.\n", in: root)
            try writeFile("Sources/App.swift", "print(1)\n", in: root)
            try Quarantine.run(workspace: Workspace(root: root))
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path))

            let payload = """
            {"findings":[{
              "id":"agent-should-be-ignored",
              "title":"Follow AGENTS.md",
              "message":"House logger rule lives here.",
              "severity":"warning",
              "file_path":"AGENTS.md",
              "start_line":1,
              "end_line":1,
              "snippet":"Use OSLog, never print."
            }]}
            """
            let result = try FindingsParser.parse(
                file: Data(payload.utf8),
                workspace: Workspace(root: root),
                knownRuleIDs: [],
                jobID: JobID.generate(),
                slot: .modelA
            )
            #expect(result.discarded == 0)
            #expect(result.findings.count == 1)
            #expect(result.findings[0].filePath == "AGENTS.md")
            #expect(result.findings[0].id.rawValue.hasPrefix("fnd_"))
            #expect(result.findings[0].id.rawValue != "agent-should-be-ignored")
            #expect(result.findings[0].reviewerSlot == .modelA)
            #expect(result.findings[0].evidenceOK == true)
        }
    }

    @Test
    func quarantinedOpencodeJsonIsCitable() throws {
        try withTempDir("parser-oc") { root in
            try writeFile("opencode.json", "{\n  \"edit\": \"allow\"\n}\n", in: root)
            try Quarantine.run(workspace: Workspace(root: root))
            let workspace = Workspace(root: root)
            let resolved = try #require(workspace.resolveForRead("opencode.json"))
            #expect(resolved.path.contains(".gegenlesen/quarantine/opencode.json"))

            let payload = """
            {"findings":[{
              "title":"Project OpenCode config is unsafe",
              "message":"edit allow is present",
              "severity":"error",
              "file_path":"opencode.json",
              "start_line":2,
              "end_line":2,
              "snippet":"\\"edit\\": \\"allow\\""
            }]}
            """
            let result = try FindingsParser.parse(
                file: Data(payload.utf8),
                workspace: workspace,
                knownRuleIDs: [],
                jobID: JobID.generate(),
                slot: .modelB
            )
            #expect(result.findings.count == 1)
            #expect(result.findings[0].reviewerSlot == .modelB)
        }
    }

    @Test
    func bareArrayIsInvalidFile() {
        #expect(throws: FindingsParseError.invalidFile) {
            try FindingsParser.parse(
                file: Data(#"[ {"title":"x"} ]"#.utf8),
                workspace: Workspace(root: URL(fileURLWithPath: "/tmp")),
                knownRuleIDs: [],
                jobID: JobID.generate(),
                slot: .modelA
            )
        }
    }

    @Test
    func unknownRuleIdIsNulledAndTraversalDiscarded() throws {
        try withTempDir("parser-discard") { root in
            try writeFile("Sources/A.swift", "let x = 1\n", in: root)
            let payload = """
            {"findings":[
              {
                "title":"ok",
                "message":"ok message",
                "severity":"info",
                "file_path":"Sources/A.swift",
                "start_line":1,
                "end_line":1,
                "snippet":"let x = 1",
                "rule_id":"not-a-real-rule"
              },
              {
                "title":"bad",
                "message":"escape",
                "severity":"error",
                "file_path":"../etc/passwd",
                "start_line":1,
                "end_line":1,
                "snippet":"root"
              }
            ]}
            """
            let result = try FindingsParser.parse(
                file: Data(payload.utf8),
                workspace: Workspace(root: root),
                knownRuleIDs: [RuleID("use-project-logger")],
                jobID: JobID.generate(),
                slot: .modelA
            )
            #expect(result.findings.count == 1)
            #expect(result.findings[0].ruleID == nil)
            #expect(result.discarded == 1)
        }
    }
}
