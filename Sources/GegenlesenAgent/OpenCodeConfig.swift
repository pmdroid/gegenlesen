import Foundation

public enum OpenCodeConfigError: Error, Sendable, Equatable {
    case jsonEncode
}

public enum OpenCodeConfig: Sendable {
    public static func policyObject(model: String, defaultAgent: String = "reviewer") -> [String: Any] {
        var object = basePolicyObject(defaultAgent: defaultAgent)
        object["model"] = model
        return object
    }

    public static func policyJSON(model: String, defaultAgent: String = "reviewer") throws -> String {
        try jsonString(policyObject(model: model, defaultAgent: defaultAgent))
    }

    public static func permissionObject() -> [String: Any] {
        [
            "task": "deny",
            "question": "deny",
            "edit": "allow",
            "bash": "allow",
            "webfetch": "allow",
            "websearch": "allow",
            "lsp": "allow",
            "glob": "allow",
            "grep": "allow",
            "list": "allow",
            "skill": "allow",
            "todowrite": "allow",
            "todoread": "allow",
            "codesearch": "allow",
            "external_directory": "allow",
            "read": [
                "*": "allow",
                "*.env": "deny",
                "*.env.*": "deny",
                "*.env.example": "allow",
            ],
        ]
    }

    public static func lspObject() -> [String: Any] {
        [
            "typescript": [
                "command": ["typescript-language-server", "--stdio"],
                "extensions": [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts"],
            ],
            "pyright": [
                "command": ["pyright-langserver", "--stdio"],
                "extensions": [".py", ".pyi"],
            ],
            "yaml": [
                "command": ["yaml-language-server", "--stdio"],
                "extensions": [".yaml", ".yml"],
            ],
            "json": [
                "command": ["vscode-json-language-server", "--stdio"],
                "extensions": [".json", ".jsonc"],
            ],
            "clangd": [
                "command": ["clangd"],
                "extensions": [".c", ".h", ".cpp", ".cc", ".cxx", ".hpp"],
            ],
        ]
    }

    public static func permissionJSON() throws -> String {
        try jsonString(permissionObject())
    }

    public static func splitModel(_ model: String) -> (providerID: String, modelID: String) {
        if let slash = model.firstIndex(of: "/") {
            return (String(model[..<slash]), String(model[model.index(after: slash)...]))
        }
        return ("", model)
    }

    private static func basePolicyObject(defaultAgent: String) -> [String: Any] {
        [
            "$schema": "https://opencode.ai/config.json",
            "autoupdate": false,
            "share": "disabled",
            "snapshot": false,
            "default_agent": defaultAgent,
            "mcp": [String: Any](),
            "plugin": [Any](),
            "permission": permissionObject(),
            "lsp": lspObject(),
            "agent": [
                "build": ["disable": true],
                "plan": ["disable": true],
                "general": ["disable": true],
                "explore": ["disable": true],
                "scout": ["disable": true],
                "reviewer": [
                    "description": "Thorough PR reviewer that writes .gegenlesen/findings.json",
                    "mode": "primary",
                    "temperature": 0.2,
                ],
                "judge": [
                    "description": "Source-checking findings judge that writes .gegenlesen/judge.json",
                    "mode": "primary",
                    "temperature": 0.0,
                ],
                "miner": [
                    "description": "Extracts candidate rules from a PR corpus into .gegenlesen/mined-rules.json",
                    "mode": "primary",
                    "temperature": 0.2,
                ],
                "harvester": [
                    "description": "Extracts house rules from a tree into .gegenlesen/harvest.json",
                    "mode": "primary",
                    "temperature": 0.2,
                ],
                "suggestion-judge": [
                    "description": "Filters harvest and mine drafts into .gegenlesen/suggestion-judge.json",
                    "mode": "primary",
                    "temperature": 0.0,
                ],
            ],
        ]
    }

    static func jsonString(_ object: Any) throws -> String {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw OpenCodeConfigError.jsonEncode
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenCodeConfigError.jsonEncode
        }
        return text
    }
}
