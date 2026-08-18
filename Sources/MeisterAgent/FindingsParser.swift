import Foundation
import MeisterCore

public enum FindingsParseError: Error, Equatable, Sendable {
    case invalidFile
}

public enum FindingsParser: Sendable {
    public static let maxFindings = 200
    public static let maxSnippetBytes = 4096

    public struct ParseResult: Sendable, Equatable {
        public var findings: [Finding]
        public var discarded: Int

        public init(findings: [Finding], discarded: Int) {
            self.findings = findings
            self.discarded = discarded
        }
    }

    public static func parse(
        file: Data,
        workspace: Workspace,
        knownRuleIDs: Set<RuleID>,
        jobID: JobID,
        slot: ReviewerSlot,
        now: Date = Date()
    ) throws -> ParseResult {
        guard let root = try? JSONSerialization.jsonObject(with: file) as? [String: Any],
              let rawFindings = root["findings"] as? [Any]
        else {
            throw FindingsParseError.invalidFile
        }

        var findings: [Finding] = []
        var discarded = 0
        findings.reserveCapacity(min(rawFindings.count, maxFindings))

        for (index, item) in rawFindings.enumerated() {
            if findings.count >= maxFindings {
                discarded += rawFindings.count - index
                break
            }
            guard let object = item as? [String: Any] else {
                discarded += 1
                continue
            }
            if let finding = parseItem(
                object,
                workspace: workspace,
                knownRuleIDs: knownRuleIDs,
                jobID: jobID,
                slot: slot,
                now: now
            ) {
                findings.append(finding)
            } else {
                discarded += 1
            }
        }
        return ParseResult(findings: findings, discarded: discarded)
    }

    public static func findingsURL(workspace: Workspace, slot: ReviewerSlot) -> URL {
        workspace.root.appendingPathComponent(".meister/findings-\(slot.rawValue).json")
    }

    private static func parseItem(
        _ object: [String: Any],
        workspace: Workspace,
        knownRuleIDs: Set<RuleID>,
        jobID: JobID,
        slot: ReviewerSlot,
        now: Date
    ) -> Finding? {
        guard let title = string(object["title"], min: 1, max: 200),
              let message = string(object["message"], min: 1, max: 4000),
              let severityRaw = object["severity"] as? String,
              let severity = Severity(rawValue: severityRaw),
              let filePath = object["file_path"] as? String,
              let startLine = int(object["start_line"]),
              let endLine = int(object["end_line"]),
              var snippet = object["snippet"] as? String
        else {
            return nil
        }
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.isEmpty { return nil }
        if startLine < 1 || endLine < startLine { return nil }
        if filePath.contains("..") || filePath.hasPrefix("/") { return nil }
        guard workspace.resolveForRead(filePath) != nil else { return nil }

        if snippet.utf8.count > maxSnippetBytes {
            snippet = String(decoding: Data(snippet.utf8.prefix(maxSnippetBytes)), as: UTF8.self)
        }

        let ruleID: RuleID?
        if let raw = object["rule_id"] as? String, !raw.isEmpty {
            let candidate = RuleID(raw)
            ruleID = knownRuleIDs.contains(candidate) ? candidate : nil
        } else {
            ruleID = nil
        }

        let rationale = (object["rationale"] as? String) ?? ""
        let confidence = object["confidence"] as? Double
        let suggested = object["suggested_patch"] as? String
        let evidence = evidenceOK(filePath: filePath, startLine: startLine, endLine: endLine, snippet: snippet, workspace: workspace)

        return Finding(
            id: FindingID.generate(at: now),
            jobID: jobID,
            ruleID: ruleID,
            phase: .agent,
            reviewerSlot: slot,
            severity: severity,
            title: title,
            message: message,
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            snippet: snippet,
            agentRationale: rationale,
            confidence: confidence,
            lifecycle: .new,
            suggestedPatch: suggested,
            fingerprint: Fingerprint.sha256(ruleID: ruleID, path: filePath, snippet: snippet),
            evidenceOK: evidence,
            createdAt: now
        )
    }

    public static func evidenceOK(
        filePath: String,
        startLine: Int,
        endLine: Int,
        snippet: String,
        workspace: Workspace
    ) -> Bool {
        guard let url = workspace.resolveForRead(filePath),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return false
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard startLine >= 1, startLine <= lines.count else { return false }
        let start = startLine - 1
        let end = min(endLine, lines.count)
        guard end > start else { return false }
        let slice = lines[start..<end].joined(separator: "\n")
        return Fingerprint.normalizeWhitespace(slice)
            .contains(Fingerprint.normalizeWhitespace(snippet))
    }

    private static func string(_ value: Any?, min: Int, max: Int) -> String? {
        guard let text = value as? String else { return nil }
        if text.count < min || text.count > max { return nil }
        return text
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
