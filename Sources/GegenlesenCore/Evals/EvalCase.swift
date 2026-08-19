import Foundation
import Yams

public enum EvalLayer: String, Codable, Sendable, Equatable {
    case rules
    case agent
    case either
}

public struct EvalCase: Sendable, Equatable {
    public var id: String
    public var directory: URL
    public var ruleID: String
    public var layer: EvalLayer
    public var mustFind: Bool
    public var filePath: String?
    public var startLine: Int?
    public var endLine: Int?
    public var tolerance: Int
    public var minSeverity: Severity?
    public var ci: Bool
    public var skipReason: String?
    public var hasTwin: Bool

    public init(
        id: String,
        directory: URL,
        ruleID: String,
        layer: EvalLayer,
        mustFind: Bool,
        filePath: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        tolerance: Int = 2,
        minSeverity: Severity? = nil,
        ci: Bool,
        skipReason: String? = nil,
        hasTwin: Bool
    ) {
        self.id = id
        self.directory = directory
        self.ruleID = ruleID
        self.layer = layer
        self.mustFind = mustFind
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.tolerance = tolerance
        self.minSeverity = minSeverity
        self.ci = ci
        self.skipReason = skipReason
        self.hasTwin = hasTwin
    }

    public var baseDirectory: URL { directory.appendingPathComponent("base", isDirectory: true) }
    public var headDirectory: URL { directory.appendingPathComponent("head", isDirectory: true) }
    public var twinDirectory: URL { directory.appendingPathComponent("twin", isDirectory: true) }

    public static func load(directory: URL, id: String) throws -> EvalCase {
        let goldURL = directory.appendingPathComponent("gold.yaml")
        let text = try String(contentsOf: goldURL, encoding: .utf8)
        let file = try YAMLDecoder().decode(GoldFile.self, from: text)
        if file.mustFind {
            guard let path = file.filePath, !path.isEmpty else {
                throw EvalError("\(id): must_find cases need file_path")
            }
            guard file.startLine != nil, file.endLine != nil else {
                throw EvalError("\(id): must_find cases need start_line and end_line")
            }
            _ = path
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.appendingPathComponent("head").path, isDirectory: &isDir),
              isDir.boolValue
        else {
            throw EvalError("\(id): missing head/")
        }
        let hasTwin = fm.fileExists(
            atPath: directory.appendingPathComponent("twin").path,
            isDirectory: &isDir
        ) && isDir.boolValue
        let layer = file.layer ?? .rules
        let ci = file.ci ?? (layer != .agent)
        return EvalCase(
            id: id,
            directory: directory,
            ruleID: file.ruleID,
            layer: layer,
            mustFind: file.mustFind,
            filePath: file.filePath,
            startLine: file.startLine,
            endLine: file.endLine,
            tolerance: file.tolerance ?? 2,
            minSeverity: file.minSeverity,
            ci: ci,
            skipReason: file.skipReason,
            hasTwin: hasTwin
        )
    }
}

public enum EvalCorpus {
    public static func load(casesRoot: URL) throws -> [EvalCase] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: casesRoot.path) else {
            throw EvalError("no eval cases at \(casesRoot.path)")
        }
        var golds: [URL] = []
        let enumerator = fm.enumerator(
            at: casesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent == "gold.yaml" {
                golds.append(item)
            }
        }
        return try golds.sorted { $0.path < $1.path }.map { gold in
            let directory = gold.deletingLastPathComponent()
            let id = relativeID(directory: directory, casesRoot: casesRoot)
            return try EvalCase.load(directory: directory, id: id)
        }
    }

    static func relativeID(directory: URL, casesRoot: URL) -> String {
        let full = directory.standardizedFileURL.path
        let root = casesRoot.standardizedFileURL.path
        if full.hasPrefix(root) {
            let dropped = String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !dropped.isEmpty { return dropped }
        }
        return directory.lastPathComponent
    }
}

public enum RepoRoot {
    public static func find(
        startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        var dir = start.standardizedFileURL
        for _ in 0..<16 {
            let cases = dir.appendingPathComponent("evals/cases")
            let pack = dir.appendingPathComponent("scripts/pack-repo.sh")
            if FileManager.default.fileExists(atPath: cases.path),
               FileManager.default.fileExists(atPath: pack.path)
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}

struct GoldFile: Codable {
    var ruleID: String
    var layer: EvalLayer?
    var mustFind: Bool
    var filePath: String?
    var startLine: Int?
    var endLine: Int?
    var tolerance: Int?
    var minSeverity: Severity?
    var ci: Bool?
    var skipReason: String?

    enum CodingKeys: String, CodingKey {
        case ruleID = "rule_id"
        case layer
        case mustFind = "must_find"
        case filePath = "file_path"
        case startLine = "start_line"
        case endLine = "end_line"
        case tolerance
        case minSeverity = "min_severity"
        case ci
        case skipReason = "skip_reason"
    }
}

public struct EvalError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}
