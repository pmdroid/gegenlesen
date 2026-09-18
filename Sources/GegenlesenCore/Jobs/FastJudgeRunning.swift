import Foundation

public protocol FastJudgeRunning: Sendable {
    func run(_ input: JudgeInputFile) async -> JudgeOutcome
}
