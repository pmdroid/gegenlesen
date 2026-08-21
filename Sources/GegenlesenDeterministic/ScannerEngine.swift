import Foundation
import GegenlesenCore

/// Dedicated scanner image: gitleaks (offline) + osv-scanner (online each run).
/// No provider keys. Network is on so OSV can refresh. Custom `/checks` JSONL
/// goes to the judge; gitleaks and osv-scanner do not.
public struct ScannerEngine: ScannerRunning {
    public static let defaultImage = "gegenlesen/scanner:0.1.0"
    public static let maxTimeoutSec = 120
    public static let maxFindings = 200
    public static let mechanicalScanners: Set<String> = ["gitleaks", "osv-scanner"]

    public var docker: any CommandRunning
    public var image: String

    public init(docker: any CommandRunning, image: String) {
        self.docker = docker
        self.image = image
    }

    public func run(
        jobID: JobID,
        files: [JobFile],
        workspace: Workspace,
        timeout: Duration,
        isCancelled: (@Sendable () async -> Bool)? = nil
    ) async -> DeterministicRunResult {
        if image.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return DeterministicRunResult(drafts: [], timedOut: false)
        }
        if await isCancelled?() == true {
            return DeterministicRunResult(drafts: [], timedOut: false)
        }
        if timeout <= .zero {
            return DeterministicRunResult(drafts: [], timedOut: true)
        }
        var dockerTimeout = Duration.seconds(Int64(Self.maxTimeoutSec))
        if timeout < dockerTimeout {
            dockerTimeout = timeout
        }
        let request = Self.request(
            jobID: jobID,
            workspace: workspace.root,
            image: image,
            timeout: dockerTimeout
        )
        let result: DockerResult
        do {
            result = try await docker.run(request)
        } catch {
            return DeterministicRunResult(
                drafts: [],
                timedOut: false,
                warnings: [
                    DeterministicWarning(
                        message: "scanner_error",
                        payloadJSON: CommandChecker.payloadJSON([
                            "stderr": CommandChecker.redact(String(describing: error)),
                        ])
                    ),
                ]
            )
        }
        if await isCancelled?() == true {
            return DeterministicRunResult(drafts: [], timedOut: false)
        }
        if result.timedOut {
            return DeterministicRunResult(
                drafts: [],
                timedOut: true,
                warnings: [DeterministicWarning(message: "scanner_timeout")]
            )
        }
        if result.exitCode != 0 {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            return DeterministicRunResult(
                drafts: [],
                timedOut: false,
                warnings: [
                    DeterministicWarning(
                        message: "scanner_error",
                        payloadJSON: CommandChecker.payloadJSON([
                            "stderr": CommandChecker.redact(stderr),
                        ])
                    ),
                ]
            )
        }
        let allowed = Set(files.map { PathGlob.normalize($0.path) })
        let parsed = Self.parseJSONL(
            stdout: result.stdout,
            workspace: workspace,
            allowedPaths: allowed
        )
        var warnings: [DeterministicWarning] = []
        if parsed.invalid > 0 {
            warnings.append(
                DeterministicWarning(
                    message: "scanner_jsonl_invalid",
                    payloadJSON: CommandChecker.payloadJSON(["invalid": parsed.invalid])
                )
            )
        }
        return DeterministicRunResult(drafts: parsed.drafts, timedOut: false, warnings: warnings)
    }

    public static func request(
        jobID: JobID,
        workspace: URL,
        image: String,
        timeout: Duration
    ) -> DockerRequest {
        let capped = min(timeout, .seconds(Int64(maxTimeoutSec)))
        return DockerRequest(
            name: ReviewContainers.scanner(jobID),
            image: image,
            argv: [],
            env: [
                "HOME": "/tmp",
                "PATH": "/usr/local/bin:/usr/bin:/bin",
            ],
            network: "bridge",
            workdir: "/workspace",
            user: "1000:1000",
            readOnly: true,
            tmpfs: ["/tmp:rw,nosuid,nodev,noexec,uid=1000,gid=1000,size=256m"],
            binds: [.init(source: workspace.path, dest: "/workspace", readOnly: true)],
            cpus: "1",
            memory: "1g",
            pidsLimit: 128,
            capDropAll: true,
            noNewPrivileges: true,
            timeout: capped,
            injectProviderKeys: false
        )
    }

    public static func parseJSONL(
        stdout: Data,
        workspace: Workspace,
        allowedPaths: Set<String>
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
                  let draft = draft(from: object, workspace: workspace, allowedPaths: allowedPaths)
            else {
                invalid += 1
                continue
            }
            drafts.append(draft)
        }
        return (drafts, invalid)
    }

    public static func ruleID(scanner: String) -> RuleID {
        RuleID.slug(from: "scanner-\(scanner)")
    }

    public static func requiresJudge(scanner: String, explicit: Bool?) -> Bool {
        if let explicit { return explicit }
        return !mechanicalScanners.contains(scanner)
    }

    private static func draft(
        from object: [String: Any],
        workspace: Workspace,
        allowedPaths: Set<String>
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
        let normalized = PathGlob.normalize(filePath)
        if !allowedPaths.isEmpty, !allowedPaths.contains(normalized) { return nil }
        guard workspace.resolveForRead(filePath) != nil else { return nil }
        if snippet.utf8.count > CommandChecker.maxSnippetBytes {
            snippet = String(decoding: Data(snippet.utf8).prefix(CommandChecker.maxSnippetBytes), as: UTF8.self)
        }
        let scanner = slugScanner(object["scanner"] as? String)
        let ruleID = Self.ruleID(scanner: scanner)
        if SecretNoiseFilter.shouldDrop(ruleID: ruleID, filePath: filePath, match: snippet) {
            return nil
        }
        let judge = requiresJudge(
            scanner: scanner,
            explicit: object["requires_judge"] as? Bool
        )
        return FindingDraft(
            ruleID: ruleID,
            phase: .deterministic,
            severity: severity,
            title: title,
            message: message,
            filePath: filePath,
            startLine: startLine,
            endLine: endLine,
            snippet: snippet,
            rationale: truncate(object["rationale"] as? String, maxBytes: CommandChecker.maxRationaleBytes),
            requiresJudge: judge,
            evidenceOK: workspace.lineSliceMatches(
                filePath: filePath,
                startLine: startLine,
                endLine: endLine,
                snippet: snippet
            )
        )
    }

    private static func slugScanner(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return "custom" }
        return RuleID.slug(from: trimmed).rawValue
    }

    private static func truncate(_ text: String?, maxBytes: Int) -> String? {
        guard var text else { return nil }
        if text.utf8.count > maxBytes {
            text = String(decoding: Data(text.utf8).prefix(maxBytes), as: UTF8.self)
        }
        return text
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
}
