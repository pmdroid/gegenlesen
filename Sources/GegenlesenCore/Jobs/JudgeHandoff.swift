import Foundation

public enum JudgeHandoff: Sendable {
    public static func stampMechanical(_ findings: [Finding], commandRuleIDs: Set<RuleID>) -> [Finding] {
        findings.map { finding in
            if finding.judgeVerdict == .drop {
                return finding
            }
            guard !JudgeMerge.shouldJudge(finding, commandRuleIDs: commandRuleIDs) else {
                return finding
            }
            var next = finding
            next.judgeVerdict = .keep
            next.judgeSeverity = finding.severity
            next.evidenceOK = true
            return next
        }
    }

    public static func prepareCandidates(
        _ findings: [Finding],
        commandRuleIDs: Set<RuleID>,
        workspace: Workspace
    ) -> [Finding] {
        findings.compactMap { finding in
            guard JudgeMerge.shouldJudge(finding, commandRuleIDs: commandRuleIDs) else {
                return nil
            }
            var next = finding
            let path = finding.filePath ?? ""
            let start = finding.startLine ?? 1
            let end = finding.endLine ?? start
            let snippet = finding.snippet ?? ""
            let slice = Evidence.actualSlice(
                filePath: path,
                startLine: start,
                endLine: end,
                workspace: workspace
            )
            next.evidenceOK = Evidence.snippetPresent(snippet: snippet, in: slice) && !slice.isEmpty
            return next
        }
    }

    public static func inputFile(from candidates: [Finding], workspace: Workspace) -> JudgeInputFile {
        inputFile(from: candidates, merged: [], workspace: workspace)
    }

    public static func inputFile(
        from candidates: [Finding],
        merged: [MergedFinding],
        workspace: Workspace
    ) -> JudgeInputFile {
        var detailByID: [String: MergedFinding] = [:]
        for group in merged {
            detailByID[group.finding.id.rawValue] = group
        }
        return JudgeInputFile(
            candidates: candidates.prefix(200).map { finding in
                let path = finding.filePath ?? ""
                let start = finding.startLine ?? 1
                let end = finding.endLine ?? start
                let snippet = finding.snippet ?? ""
                let detail = detailByID[finding.id.rawValue]
                return JudgeCandidate(
                    id: finding.id,
                    ruleID: finding.ruleID,
                    severity: finding.severity,
                    title: finding.title,
                    message: finding.message,
                    filePath: path,
                    startLine: start,
                    endLine: end,
                    snippet: snippet,
                    rationale: nonempty(finding.agentRationale),
                    phase: finding.phase,
                    evidenceOK: finding.evidenceOK ?? false,
                    actualSlice: Evidence.actualSlice(
                        filePath: path,
                        startLine: start,
                        endLine: end,
                        workspace: workspace
                    ),
                    sources: detail?.sources.map(\.rawValue),
                    agreement: detail?.agreement.rawValue
                )
            }
        )
    }

    public static func writeInput(
        _ file: JudgeInputFile,
        workspace: Workspace,
        blobs: BlobStore,
        jobID: JobID
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        let gegenlesen = workspace.root.appendingPathComponent(".gegenlesen", isDirectory: true)
        try FileManager.default.createDirectory(at: gegenlesen, withIntermediateDirectories: true)
        let dest = gegenlesen.appendingPathComponent("judge-input.json")
        try data.write(to: dest, options: .atomic)
        try persist(data, to: blobs.findingsURL(jobID: jobID.rawValue, stage: "pre-judge"))
    }

    public static func persistAgentBlob(workspace: Workspace, blobs: BlobStore, jobID: JobID) {
        let fm = FileManager.default
        let names = [
            "agent-findings.json",
            "findings-model_a.json",
            "findings-model_b.json",
            "findings.json",
        ]
        for name in names {
            let source = workspace.root.appendingPathComponent(".gegenlesen/\(name)")
            if fm.fileExists(atPath: source.path), let data = try? Data(contentsOf: source) {
                try? persist(data, to: blobs.findingsURL(jobID: jobID.rawValue, stage: "agent"))
                if name != "agent-findings.json" {
                    let dest = workspace.root.appendingPathComponent(".gegenlesen/agent-findings.json")
                    try? fm.removeItem(at: dest)
                    try? fm.copyItem(at: source, to: dest)
                }
                return
            }
        }
    }

    public static func persistPostJudge(_ findings: [Finding], blobs: BlobStore, jobID: JobID) {
        let rows: [[String: Any]] = findings.map { finding in
            var row: [String: Any] = [
                "id": finding.id.rawValue,
                "phase": finding.phase.rawValue,
                "severity": finding.severity.rawValue,
                "title": finding.title,
                "message": finding.message,
            ]
            if let verdict = finding.judgeVerdict {
                row["judge_verdict"] = verdict.rawValue
            }
            if let severity = finding.judgeSeverity {
                row["judge_severity"] = severity.rawValue
            }
            if let rationale = finding.judgeRationale {
                row["judge_rationale"] = rationale
            }
            if let evidence = finding.evidenceOK {
                row["evidence_ok"] = evidence
            }
            if let path = finding.filePath {
                row["file_path"] = path
            }
            return row
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["findings": rows],
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }
        try? persist(data, to: blobs.findingsURL(jobID: jobID.rawValue, stage: "post-judge"))
    }

    public static func persistTranscript(_ data: Data, blobs: BlobStore, jobID: JobID) {
        guard !data.isEmpty else { return }
        try? persist(data, to: blobs.transcriptURL(jobID: jobID.rawValue, phase: "judge"))
    }

    private static func persist(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
