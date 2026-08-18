import Foundation
import MeisterCore

public protocol DeterministicChecker: Sendable {
    func check(file: JobFile, bytes: Data, workspace: Workspace, rule: Rule) throws -> [FindingDraft]
}

public struct DeterministicEngine: DeterministicRunning {
    public var perFileCap: Int
    public var oasdiffAvailable: Bool

    public init(
        perFileCap: Int = 50,
        oasdiffAvailable: Bool = OpenAPIBreakChecker.binaryAvailable()
    ) {
        self.perFileCap = perFileCap
        self.oasdiffAvailable = oasdiffAvailable
    }

    public func run(
        files: [JobFile],
        workspace: Workspace,
        rules: [Rule],
        timeout: Duration
    ) async -> DeterministicRunResult {
        let deadline = ContinuousClock.now + timeout
        let selected = RuleSelector().select(rules: rules, files: files)
        var drafts: [FindingDraft] = []
        for item in selected {
            if ContinuousClock.now >= deadline {
                return DeterministicRunResult(drafts: drafts, timedOut: true)
            }
            switch item.rule.payload {
            case .semantic, .command:
                continue
            case .openapiBreak:
                if !oasdiffAvailable {
                    continue
                }
                continue
            default:
                break
            }
            do {
                let produced = try check(selected: item, workspace: workspace)
                drafts.append(contentsOf: produced)
            } catch {
                continue
            }
        }
        if ContinuousClock.now >= deadline {
            return DeterministicRunResult(drafts: drafts, timedOut: true)
        }
        return DeterministicRunResult(drafts: drafts, timedOut: false)
    }

    private func check(selected: SelectedRule, workspace: Workspace) throws -> [FindingDraft] {
        var drafts: [FindingDraft] = []
        for file in selected.files {
            let bytes: Data
            if needsBytes(selected.rule.payload) {
                guard let url = workspace.resolveForRead(file.path),
                      FileManager.default.isReadableFile(atPath: url.path)
                else { continue }
                bytes = try Data(contentsOf: url)
            } else {
                bytes = Data()
            }
            let checker = try checker(for: selected.rule)
            let hits = try checker.check(
                file: file,
                bytes: bytes,
                workspace: workspace,
                rule: selected.rule
            )
            drafts.append(contentsOf: Array(hits.prefix(perFileCap)))
        }
        return drafts
    }

    private func needsBytes(_ payload: RulePayload) -> Bool {
        switch payload {
        case .regex, .denyAPI:
            return true
        default:
            return false
        }
    }

    private func checker(for rule: Rule) throws -> any DeterministicChecker {
        switch rule.payload {
        case .regex:
            return try RegexChecker(rule: rule)
        case .denyAPI:
            return DenyListChecker()
        case .siblingTest:
            return SiblingTestChecker()
        case .command:
            return CommandChecker()
        case .openapiBreak:
            return OpenAPIBreakChecker()
        case .semantic:
            throw CheckerSkip()
        }
    }
}

struct CheckerSkip: Error {}