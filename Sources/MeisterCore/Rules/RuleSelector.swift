import Foundation

public struct SelectedRule: Sendable, Equatable {
    public var rule: Rule
    public var files: [JobFile]

    public init(rule: Rule, files: [JobFile]) {
        self.rule = rule
        self.files = files
    }
}

public struct RuleSelector: Sendable {
    public init() {}

    public func select(rules: [Rule], files: [JobFile]) -> [SelectedRule] {
        var selected: [SelectedRule] = []
        for rule in rules {
            guard rule.enabled, rule.deletedAt == nil else { continue }
            let matched = files.filter { matches(rule: rule, file: $0) }
            if !matched.isEmpty {
                selected.append(SelectedRule(rule: rule, files: matched))
            }
        }
        return selected
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
}