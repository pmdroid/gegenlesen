import Foundation

public enum FileChangeStatus: String, Codable, Sendable, Equatable {
    case added, modified, deleted, renamed
}

public enum Language: String, Codable, Sendable, Equatable {
    case swift, typescript, javascript, python, go, rust, jvm
    case c, ruby, csharp, shell, yaml, json, markdown, other
}
