import Foundation

public enum OpenCodeConfig: Sendable {
    public static let findingsAllowlist = [
        ".meister/findings.json",
        ".meister/findings-model_a.json",
        ".meister/findings-model_b.json",
        ".meister/judge.json",
        ".meister/mined-rules.json",
        ".meister/transcript.json",
    ]

    public static func policyObject(model: String, defaultAgent: String = "reviewer") -> [String: Any] {
        var object = basePolicyObject(defaultAgent: defaultAgent)
        object["model"] = model
        return object
    }

    public static func policyJSON(model: String, defaultAgent: String = "reviewer") -> String {
        jsonString(policyObject(model: model, defaultAgent: defaultAgent))
    }

    public static func permissionObject() -> [String: Any] {
        [
            "task": "deny",
            "webfetch": "deny",
            "websearch": "deny",
            "external_directory": "deny",
            "question": "deny",
            "edit": [
                "*": "deny",
                ".meister/findings.json": "allow",
                ".meister/findings-model_a.json": "allow",
                ".meister/findings-model_b.json": "allow",
                ".meister/judge.json": "allow",
                ".meister/mined-rules.json": "allow",
                ".meister/transcript.json": "allow",
            ],
            "bash": [
                "*": "deny",
                "git diff*": "allow",
                "git log*": "allow",
                "git show*": "allow",
                "git rev-parse*": "allow",
                "git status*": "allow",
                "rg *": "allow",
                "grep *": "allow",
            ],
            "read": [
                "*": "allow",
                "*.env": "deny",
                "*.env.*": "deny",
                "*.env.example": "allow",
            ],
        ]
    }

    public static func permissionJSON() -> String {
        jsonString(permissionObject())
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
            "subagent_depth": 0,
            "default_agent": defaultAgent,
            "mcp": [String: Any](),
            "plugin": [Any](),
            "permission": permissionObject(),
            "agent": [
                "build": ["disable": true],
                "plan": ["disable": true],
                "general": ["disable": true],
                "explore": ["disable": true],
                "scout": ["disable": true],
                "reviewer": [
                    "description": "Read-only PR reviewer that writes .meister/findings.json",
                    "mode": "primary",
                    "temperature": 0.1,
                ],
                "judge": [
                    "description": "Conservative findings judge that writes .meister/judge.json",
                    "mode": "primary",
                    "temperature": 0.0,
                ],
                "miner": [
                    "description": "Extracts candidate rules from a PR corpus into .meister/mined-rules.json",
                    "mode": "primary",
                    "temperature": 0.2,
                ],
            ],
        ]
    }

    static func jsonString(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
