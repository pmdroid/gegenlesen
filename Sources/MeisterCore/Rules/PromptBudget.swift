import Foundation

public struct PromptBudget: Sendable, Equatable {
    public var tokenBudget: Int

    public init(tokenBudget: Int = 6000) {
        self.tokenBudget = max(tokenBudget, 0)
    }

    public static func tokens(_ text: String) -> Int {
        (text.utf8.count + 3) / 4
    }

    public func apply(_ rules: [Rule]) -> [Rule] {
        var working = rules
        for index in working.indices.reversed() {
            if totalTokens(working) <= tokenBudget { return working }
            working[index] = stripFewShots(working[index])
        }
        while totalTokens(working) > tokenBudget {
            guard let index = working.lastIndex(where: { $0.provenance != .handwritten }) else {
                break
            }
            working.remove(at: index)
        }
        return working
    }

    public func totalTokens(_ rules: [Rule]) -> Int {
        rules.reduce(0) { $0 + Self.tokens(Self.render($1)) }
    }

    public static func render(_ rule: Rule) -> String {
        var parts = [rule.title]
        switch rule.payload {
        case .semantic(let instruction, let fewShots):
            parts.append(instruction)
            parts.append(contentsOf: fewShots)
        default:
            break
        }
        return parts.joined(separator: "\n")
    }

    private func stripFewShots(_ rule: Rule) -> Rule {
        var next = rule
        if case .semantic(let instruction, let fewShots) = rule.payload, !fewShots.isEmpty {
            next.payload = .semantic(instruction: instruction, fewShots: [])
        }
        return next
    }
}
