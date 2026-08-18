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
        if ContinuousClock.now >= deadline {
            return DeterministicRunResult(drafts: [], timedOut: true)
        }
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
            let checker: any DeterministicChecker
            do {
                checker = try self.checker(for: item.rule)
            } catch {
                continue
            }
            for file in item.files {
                if ContinuousClock.now >= deadline {
                    return DeterministicRunResult(drafts: drafts, timedOut: true)
                }
                switch await checkFile(
                    file: file,
                    workspace: workspace,
                    rule: item.rule,
                    checker: checker,
                    deadline: deadline
                ) {
                case .hits(let hits):
                    drafts.append(contentsOf: hits)
                case .skip:
                    continue
                case .timedOut:
                    return DeterministicRunResult(drafts: drafts, timedOut: true)
                }
            }
        }
        if ContinuousClock.now >= deadline {
            return DeterministicRunResult(drafts: drafts, timedOut: true)
        }
        return DeterministicRunResult(drafts: drafts, timedOut: false)
    }

    private enum FileCheckOutcome: Sendable {
        case hits([FindingDraft])
        case skip
        case timedOut
    }

    private func checkFile(
        file: JobFile,
        workspace: Workspace,
        rule: Rule,
        checker: any DeterministicChecker,
        deadline: ContinuousClock.Instant
    ) async -> FileCheckOutcome {
        let remaining = deadline - ContinuousClock.now
        if remaining <= .zero {
            return .timedOut
        }
        let bytes: Data
        if needsBytes(rule.payload) {
            guard let url = workspace.resolveForRead(file.path),
                  FileManager.default.isReadableFile(atPath: url.path)
            else { return .skip }
            do {
                bytes = try Data(contentsOf: url)
            } catch {
                return .skip
            }
        } else {
            bytes = Data()
        }
        if ContinuousClock.now >= deadline {
            return .timedOut
        }

        let cap = perFileCap
        return await withCheckedContinuation { continuation in
            let box = OnceBox<FileCheckOutcome>()
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let hits = try checker.check(
                        file: file,
                        bytes: bytes,
                        workspace: workspace,
                        rule: rule
                    )
                    box.resume(continuation, with: .hits(Array(hits.prefix(cap))))
                } catch {
                    box.resume(continuation, with: .skip)
                }
            }
            let nanos = remaining.components.seconds * 1_000_000_000
                + remaining.components.attoseconds / 1_000_000_000
            let delay = DispatchTimeInterval.nanoseconds(Int(clamping: max(nanos, 0)))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
                box.resume(continuation, with: .timedOut)
            }
        }
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

/// First resume wins so a timed-out file check does not wait for the checker to finish.
private final class OnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    func resume(
        _ continuation: CheckedContinuation<T, Never>,
        with value: T
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        continuation.resume(returning: value)
    }
}