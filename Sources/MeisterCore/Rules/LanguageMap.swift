import Foundation

public enum LanguageMap: Sendable {
    public static func language(forPath path: String) -> Language {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let ext: String
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            ext = String(name[name.index(after: dot)...]).lowercased()
        } else {
            return .other
        }

        switch ext {
        case "swift":
            return .swift
        case "ts", "tsx":
            return .typescript
        case "js", "jsx", "mjs", "cjs":
            return .javascript
        case "py", "pyi":
            return .python
        case "go":
            return .go
        case "rs":
            return .rust
        case "java", "kt", "kts":
            return .jvm
        case "c", "h", "cc", "cpp", "hpp":
            return .c
        case "rb":
            return .ruby
        case "cs":
            return .csharp
        case "sh", "bash", "zsh":
            return .shell
        case "yml", "yaml":
            return .yaml
        case "json":
            return .json
        case "md":
            return .markdown
        default:
            return .other
        }
    }
}
