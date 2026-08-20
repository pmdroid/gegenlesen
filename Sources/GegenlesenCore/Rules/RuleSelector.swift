import Foundation

public struct SelectedRule: Sendable, Equatable {
    public var rule: Rule
    public var files: [JobFile]
    public var score: Double

    public init(rule: Rule, files: [JobFile], score: Double = 0) {
        self.rule = rule
        self.files = files
        self.score = score
    }
}

public struct RuleSelector: Sendable {
    public init() {}

    public func select(
        rules: [Rule],
        files: [JobFile],
        ftsScores: [RuleID: Double] = [:]
    ) -> [SelectedRule] {
        var deterministic: [SelectedRule] = []
        var semantic: [SelectedRule] = []
        for rule in rules {
            guard rule.enabled, rule.deletedAt == nil else { continue }
            if rule.payload.isRiskWeight { continue }
            let matched = files.filter { matches(rule: rule, file: $0) }
            guard !matched.isEmpty else { continue }
            if rule.payload.isSemantic || rule.kind == .semantic {
                let score = rank(
                    rule: rule,
                    files: matched,
                    ftsScore: ftsScores[rule.id] ?? 0
                )
                semantic.append(SelectedRule(rule: rule, files: matched, score: score))
            } else {
                deterministic.append(SelectedRule(rule: rule, files: matched, score: 0))
            }
        }
        semantic.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.rule.id.rawValue < rhs.rule.id.rawValue
        }
        return deterministic + semantic
    }

    public func rank(rule: Rule, files: [JobFile], ftsScore: Double) -> Double {
        var score = ftsScore
        if hasSpecificGlobHit(rule: rule, files: files) {
            score += 3
        }
        if hasConcreteLanguageHit(rule: rule, files: files) {
            score += 2
        }
        if rule.provenance == .handwritten {
            score += 1
        }
        return score
    }

    public func matches(rule: Rule, file: JobFile) -> Bool {
        if file.status == .deleted { return false }
        if PathGlob.defaultIgnores.matches(file.path) { return false }
        guard languageMatches(rule.languages, file: file) else { return false }
        let globs = rule.pathGlobs.isEmpty ? ["**/*"] : rule.pathGlobs
        return PathGlob(globs).matches(file.path)
    }

    public func languageMatches(_ languages: [String], file: JobFile) -> Bool {
        if languages.contains("*") { return true }
        let language = file.language ?? LanguageMap.language(forPath: file.path)
        return languages.contains(language.rawValue)
    }

    private func hasSpecificGlobHit(rule: Rule, files: [JobFile]) -> Bool {
        let globs = rule.pathGlobs.filter { glob in
            let trimmed = glob.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed != "**/*" && trimmed != "*" && !trimmed.hasPrefix("!")
        }
        guard !globs.isEmpty else { return false }
        let matcher = PathGlob(globs)
        return files.contains { matcher.matches($0.path) }
    }

    private func hasConcreteLanguageHit(rule: Rule, files: [JobFile]) -> Bool {
        let concrete = rule.languages.filter { $0 != "*" && !$0.isEmpty }
        guard !concrete.isEmpty else { return false }
        return files.contains { file in
            let language = file.language ?? LanguageMap.language(forPath: file.path)
            return concrete.contains(language.rawValue)
        }
    }
}
