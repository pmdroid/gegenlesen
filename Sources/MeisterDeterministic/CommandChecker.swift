import Foundation
import MeisterCore

public struct CommandCheckOutcome: Sendable {
    public var drafts: [FindingDraft]
    public var warnings: [DeterministicWarning]
    public var timedOut: Bool

    public init(
        drafts: [FindingDraft] = [],
        warnings: [DeterministicWarning] = [],
        timedOut: Bool = false
    ) {
        self.drafts = drafts
        self.warnings = warnings
        self.timedOut = timedOut
    }
}

/// Phase `.command`: runner image, no OpenCode, no provider keys, `--network none`.
public struct CommandChecker: Sendable {
    public static let maxTimeoutSec = 20
    public static let maxFindings = 200
    public static let maxSnippetBytes = 4096
    public static let maxLogBytes = 4096

    public var docker: any CommandRunning
    public var image: String

    public init(docker: any CommandRunning, image: String) {
        self.docker = docker
        self.image = image
    }

    public func run(
        jobID: JobID,
        workspace: Workspace,
        rule: Rule,
        timeout: Duration
    ) async -> CommandCheckOutcome {
        guard case .command(let argv, let timeoutSec) = rule.payload else {
            return CommandCheckOutcome()
        }
        if argv.isEmpty {
            return CommandCheckOutcome(warnings: [
                Self.ruleError(ruleID: rule.id, stderr: "empty argv"),
            ])
        }
        if timeout <= .zero {
            return CommandCheckOutcome(timedOut: true)
        }
        let capped = min(max(timeoutSec, 1), Self.maxTimeoutSec)
        var dockerTimeout = Duration.seconds(Int64(capped))
        if timeout < dockerTimeout {
            dockerTimeout = timeout
        }
        let request = Self.request(
            jobID: jobID,
            ruleID: rule.id,
            workspace: workspace.root,
            image: image,
            argv: argv,
            timeout: dockerTimeout
        )
        let result: DockerResult
        do {
            result = try await docker.run(request)
        } catch {
            return CommandCheckOutcome(warnings: [
                Self.ruleError(ruleID: rule.id, stderr: String(describing: error)),
            ])
        }
        if result.timedOut, timeout <= dockerTimeout {
            return CommandCheckOutcome(timedOut: true)
        }
        if result.exitCode != 0 || result.timedOut {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            return CommandCheckOutcome(warnings: [
                Self.ruleError(ruleID: rule.id, stderr: stderr),
            ])
        }
        let parsed = Self.parseJSONL(stdout: result.stdout, workspace: workspace, rule: rule)
        var warnings: [DeterministicWarning] = []
        if parsed.invalid > 0 {
            warnings.append(
                DeterministicWarning(
                    message: "command_jsonl_invalid",
                    payloadJSON: #"{"rule_id":"\#(rule.id.rawValue)","invalid":\#(parsed.invalid)}"#
                )
            )
        }
        return CommandCheckOutcome(drafts: parsed.drafts, warnings: warnings)
    }

    public static func request(
        jobID: JobID,
        ruleID: RuleID,
        workspace: URL,
        image: String,
        argv: [String],
        timeout: Duration
    ) -> DockerRequest {
        sandboxRequest(
            name: ReviewContainers.command(jobID, ruleID),
            workspace: workspace,
            image: image,
            argv: argv,
            timeout: timeout
        )
    }

    public static func sandboxRequest(
        name: String,
        workspace: URL,
        image: String,
        argv: [String],
        timeout: Duration
    ) -> DockerRequest {
        DockerRequest(
            name: name,
            image: image,
            argv: argv,
            env: [
                "HOME": "/tmp",
                "PATH": "/usr/bin:/bin",
            ],
            network: "none",
            workdir: "/workspace",
            user: "1000:1000",
            readOnly: true,
            tmpfs: ["/tmp:rw,nosuid,nodev,uid=1000,gid=1000,size=64m"],
            binds: [.init(source: workspace.path, dest: "/workspace")],
            cpus: "1",
            memory: "512m",
            pidsLimit: 64,
            capDropAll: true,
            noNewPrivileges: true,
            timeout: timeout,
            injectProviderKeys: false
        )
    }

    public static func parseJSONL(
        stdout: Data,
        workspace: Workspace,
        rule: Rule
    ) -> (drafts: [FindingDraft], invalid: Int) {
        let text = String(data: stdout, encoding: .utf8) ?? ""
        var drafts: [FindingDraft] = []
        var invalid = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if drafts.count >= maxFindings {
                invalid += 1
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
                  let draft = draft(from: object, workspace: workspace, rule: rule)
            else {
                invalid += 1
                continue
            }
            drafts.append(draft)
        }
        return (drafts, invalid)
    }

    public static func redact(_ text: String) -> String {
        var result = text
        result = result.replacing(
            #/(ANTHROPIC_API_KEY|OPENAI_API_KEY|OPENROUTER_API_KEY)\s*[:=]\s*["']?[^\s"',}]+["']?/#,
            with: { match in
                "\(match.output.1)=[REDACTED]"
            }
        )
        result = result.replacing(#/sk-[A-Za-z0-9_-]{8,}/#, with: { _ in "[REDACTED]" })
        result = result.replacing(#/xox[baprs]-[A-Za-z0-9-]{8,}/#, with: { _ in "[REDACTED]" })
        if result.utf8.count > maxLogBytes {
            result = String(decoding: Data(result.utf8.prefix(maxLogBytes)), as: UTF8.self)
        }
        return result
    }

    private static func ruleError(ruleID: RuleID, stderr: String) -> DeterministicWarning {
        let redacted = redact(stderr)
        let escaped = jsonEscape(redacted)
        return DeterministicWarning(
            message: "command_error",
            payloadJSON: #"{"rule_id":"\#(ruleID.rawValue)","stderr":"\#(escaped)"}"#
        )
    }

    private static func draft(
        from object: [String: Any],
        workspace: Workspace,
        rule: Rule
    ) -> FindingDraft? {
        guard let title = boundedString(object["title"], min: 1, max: 200),
              let message = boundedString(object["message"], min: 1, max: 4000),
              let severityRaw = object["severity"] as? String,
              let severity = Severity(rawValue: severityRaw),
              let filePath = object["file_path"] as? String,
              let startLine = intValue(object["start_line"]),
              let endLine = intValue(object["end_line"]),
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
        let rationale = object["rationale"] as? String
        let confidence = object["confidence"] as? Double
        let suggested = object["suggested_patch"] as? String
        return FindingDraft(
            ruleID: rule.id,
            phase: .deterministic,
            severity: severity,
            title: title,
            message: message,
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            snippet: snippet,
            rationale: rationale,
            confidence: confidence,
            suggestedPatch: suggested
        )
    }

    private static func boundedString(_ value: Any?, min: Int, max: Int) -> String? {
        guard let text = value as? String else { return nil }
        if text.count < min || text.count > max { return nil }
        return text
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func jsonEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}
