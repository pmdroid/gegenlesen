import Foundation
import MeisterCore

public struct CommandChecker: DeterministicChecker {
    public init() {}

    public func check(file: JobFile, bytes: Data, workspace: Workspace, rule: Rule) throws -> [FindingDraft] {
        []
    }
}