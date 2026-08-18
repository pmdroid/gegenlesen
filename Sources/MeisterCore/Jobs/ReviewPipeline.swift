import Foundation

public struct ReviewPipeline: Sendable {
    public var store: Store
    public var skipAgent: Bool
    public var identifyTimeout: Duration

    public init(store: Store, skipAgent: Bool = true, identifyTimeout: Duration = .seconds(60)) {
        self.store = store
        self.skipAgent = skipAgent
        self.identifyTimeout = identifyTimeout
    }

    public func run(jobID: JobID) async throws {
        do {
            try await runPhases(jobID: jobID)
        } catch is JobStateMachine.IllegalTransition {
            return
        } catch let error as StoreJobError where error == .notFound {
            return
        } catch {
            _ = try? await store.apply(
                jobID: jobID,
                event: .identifyFailed("internal"),
                errorMessage: String(describing: error)
            )
        }
    }

    private func runPhases(jobID: JobID) async throws {
        guard let existing = try await store.job(id: jobID) else { return }
        if existing.status.isTerminal { return }

        try await store.appendEvent(jobID: jobID, level: .info, message: "dequeued")
        _ = try await store.apply(jobID: jobID, event: .dequeued)
        if try await stopped(jobID) { return }

        let workspace = store.blobs.workspaceURL(jobID: jobID.rawValue)
        let archive = store.blobs.archiveURL(jobID: jobID.rawValue)
        do {
            try ArchiveUnpacker().unpack(archive: archive, into: workspace)
            try await store.appendEvent(jobID: jobID, level: .info, message: "unpacked")
            _ = try await store.apply(jobID: jobID, event: .unpackOK)
        } catch {
            _ = try await store.apply(
                jobID: jobID,
                event: .unpackFailed(String(describing: error)),
                errorMessage: String(describing: error)
            )
            try await store.appendEvent(jobID: jobID, level: .error, message: "unpack_failed")
            return
        }
        if try await stopped(jobID) { return }

        do {
            let meta = loadIdentifyMeta(jobID: jobID)
            let patch = loadMultipartPatch(jobID: jobID)
            let identifier = ChangeSetIdentifier(
                workspace: workspace,
                blobs: store.blobs,
                jobID: jobID,
                meta: meta,
                multipartPatch: patch,
                timeout: identifyTimeout
            )
            let changeSet = try identifier.identify()
            try await store.replaceJobFiles(changeSet.files)
            try await store.appendEvent(jobID: jobID, level: .info, message: "identified")
            _ = try await store.apply(
                jobID: jobID,
                event: .identifyOK,
                baseSHA: changeSet.baseSHA,
                headSHA: changeSet.headSHA,
                fileCount: changeSet.files.count
            )
        } catch let error as IdentifyError {
            _ = try await store.apply(
                jobID: jobID,
                event: .identifyFailed(error.errorMessage),
                errorMessage: error.errorMessage
            )
            try await store.appendEvent(jobID: jobID, level: .error, message: error.errorMessage)
            return
        } catch {
            _ = try await store.apply(
                jobID: jobID,
                event: .identifyFailed("no_change_set"),
                errorMessage: "no_change_set"
            )
            try await store.appendEvent(jobID: jobID, level: .error, message: "no_change_set")
            return
        }
        if try await stopped(jobID) { return }

        try await store.appendEvent(jobID: jobID, level: .info, message: "selecting_rules")
        _ = try await store.apply(jobID: jobID, event: .rulesOK)
        if try await stopped(jobID) { return }

        let files = try await store.jobFiles(id: jobID)
        let newWork = !files.isEmpty
        try await store.appendEvent(jobID: jobID, level: .info, message: "deterministic")
        _ = try await store.apply(
            jobID: jobID,
            event: .deterministicDone(newWork: newWork, skipAgent: skipAgent)
        )
        try await store.appendEvent(
            jobID: jobID,
            level: .info,
            message: skipAgent ? "succeeded" : "reviewing"
        )
    }

    private func stopped(_ jobID: JobID) async throws -> Bool {
        try await store.job(id: jobID)?.status.isTerminal ?? true
    }

    private func loadIdentifyMeta(jobID: JobID) -> IdentifyMeta {
        let url = store.blobs.identifyMetaURL(jobID: jobID.rawValue)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(IdentifyMetaFile.self, from: data)
        else {
            return IdentifyMeta()
        }
        return IdentifyMeta(
            baseSHA: decoded.baseSHA,
            headSHA: decoded.headSHA,
            baseRef: decoded.baseRef,
            headRef: decoded.headRef,
            parentHeadSHA: decoded.parentHeadSHA
        )
    }

    private func loadMultipartPatch(jobID: JobID) -> Data? {
        let url = store.blobs.patchURL(jobID: jobID.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }
}

public struct IdentifyMetaFile: Codable, Sendable, Equatable {
    public var baseSHA: String?
    public var headSHA: String?
    public var baseRef: String?
    public var headRef: String?
    public var parentHeadSHA: String?

    public init(
        baseSHA: String? = nil,
        headSHA: String? = nil,
        baseRef: String? = nil,
        headRef: String? = nil,
        parentHeadSHA: String? = nil
    ) {
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.baseRef = baseRef
        self.headRef = headRef
        self.parentHeadSHA = parentHeadSHA
    }

    enum CodingKeys: String, CodingKey {
        case baseSHA = "base_sha"
        case headSHA = "head_sha"
        case baseRef = "base_ref"
        case headRef = "head_ref"
        case parentHeadSHA = "parent_head_sha"
    }
}
