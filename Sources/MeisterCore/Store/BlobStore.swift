import Foundation

/// Filesystem layout under `var/` — no SQL, no secrets.
public struct BlobStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var sqliteURL: URL {
        root.appendingPathComponent("meister.sqlite", isDirectory: false)
    }

    public var blobs: URL { root.appendingPathComponent("blobs", isDirectory: true) }
    public var archives: URL { blobs.appendingPathComponent("archives", isDirectory: true) }
    public var patches: URL { blobs.appendingPathComponent("patches", isDirectory: true) }
    public var transcripts: URL { blobs.appendingPathComponent("transcripts", isDirectory: true) }
    public var findings: URL { blobs.appendingPathComponent("findings", isDirectory: true) }
    public var corpus: URL { blobs.appendingPathComponent("corpus", isDirectory: true) }
    public var workspaces: URL { root.appendingPathComponent("workspaces", isDirectory: true) }

    public func archiveURL(jobID: String) -> URL {
        archives.appendingPathComponent("\(jobID).tar.gz", isDirectory: false)
    }

    public func identifyMetaURL(jobID: String) -> URL {
        archives.appendingPathComponent("\(jobID).identify.json", isDirectory: false)
    }

    public func patchURL(jobID: String) -> URL {
        patches.appendingPathComponent("\(jobID).patch", isDirectory: false)
    }

    public func transcriptURL(jobID: String, phase: String, suffix: String = "ndjson") -> URL {
        transcripts.appendingPathComponent("\(jobID)-\(phase).\(suffix)", isDirectory: false)
    }

    public func findingsURL(jobID: String, stage: String) -> URL {
        findings.appendingPathComponent("\(jobID)-\(stage).json", isDirectory: false)
    }

    public func corpusItemDirectory(itemID: String) -> URL {
        corpus.appendingPathComponent(itemID, isDirectory: true)
    }

    public func workspaceURL(jobID: String) -> URL {
        workspaces.appendingPathComponent(jobID, isDirectory: true)
    }

    public func ensureLayout() throws {
        let fm = FileManager.default
        for directory in [archives, patches, transcripts, findings, corpus, workspaces] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
