import Foundation

public struct ReviewPipeline: Sendable {
    public var store: Store
    public var skipAgent: Bool
    public var identifyTimeout: Duration
    public var deterministicTimeout: Duration
    public var deterministic: (any DeterministicRunning)?
    public var reviewer: (any ReviewerRunning)?

    public init(
        store: Store,
        skipAgent: Bool = true,
        identifyTimeout: Duration = .seconds(60),
        deterministicTimeout: Duration = .seconds(30),
        deterministic: (any DeterministicRunning)? = nil,
        reviewer: (any ReviewerRunning)? = nil
    ) {
        self.store = store
        self.skipAgent = skipAgent
        self.identifyTimeout = identifyTimeout
        self.deterministicTimeout = deterministicTimeout
        self.deterministic = deterministic
        self.reviewer = reviewer
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

        let workspaceURL = store.blobs.workspaceURL(jobID: jobID.rawValue)
        let archive = store.blobs.archiveURL(jobID: jobID.rawValue)
        do {
            try ArchiveUnpacker().unpack(archive: archive, into: workspaceURL)
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
                workspace: workspaceURL,
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

        let files = try await store.jobFiles(id: jobID)
        let rules: [Rule]
        do {
            rules = try await store.listRules(RuleListFilter(enabled: true))
            let selected = RuleSelector().select(rules: rules, files: files)
            try await store.appendEvent(
                jobID: jobID,
                level: .info,
                message: "selecting_rules",
                payloadJSON: #"{"count":\#(selected.count)}"#
            )
            _ = try await store.apply(jobID: jobID, event: .rulesOK)
        } catch {
            _ = try await store.apply(
                jobID: jobID,
                event: .rulesFailed("internal"),
                errorMessage: "internal"
            )
            try await store.appendEvent(jobID: jobID, level: .error, message: "rules_failed")
            return
        }
        if try await stopped(jobID) { return }

        let newWork = !files.isEmpty
        try await store.appendEvent(jobID: jobID, level: .info, message: "deterministic")
        let result: DeterministicRunResult
        if let deterministic {
            result = await deterministic.run(
                files: files,
                workspace: Workspace(root: workspaceURL),
                rules: rules,
                timeout: deterministicTimeout,
                isCancelled: { [store, jobID] in
                    (try? await store.job(id: jobID))?.status.isTerminal ?? true
                }
            )
        } else {
            result = DeterministicRunResult(drafts: [], timedOut: false)
        }
        if try await stopped(jobID) { return }
        if result.timedOut {
            _ = try await store.apply(jobID: jobID, event: .deterministicTimeout)
            try await store.appendEvent(jobID: jobID, level: .error, message: "deterministic_timeout")
            return
        }
        for warning in result.warnings {
            try await store.appendEvent(
                jobID: jobID,
                level: .warning,
                message: warning.message,
                payloadJSON: warning.payloadJSON
            )
        }
        if !result.drafts.isEmpty {
            _ = try await store.insertFindings(result.drafts, jobID: jobID)
        }
        _ = try await store.apply(
            jobID: jobID,
            event: .deterministicDone(newWork: newWork, skipAgent: skipAgent)
        )
        try await store.appendEvent(
            jobID: jobID,
            level: .info,
            message: skipAgent ? "succeeded" : "reviewing"
        )
        if skipAgent { return }
        if try await stopped(jobID) { return }

        guard let job = try await store.job(id: jobID) else { return }
        guard let reviewer else {
            _ = try await store.apply(
                jobID: jobID,
                event: .reviewFailed("reviewer_unavailable"),
                errorMessage: "reviewer_unavailable"
            )
            return
        }

        let nameA = ReviewContainers.slot(jobID, .modelA)
        let nameB = ReviewContainers.slot(jobID, .modelB)
        let judgeName = ReviewContainers.judge(jobID)
        try await store.updateJobContainers(
            jobID: jobID,
            containerName: judgeName,
            containerNameA: nameA,
            containerNameB: nameB
        )
        if try await stopped(jobID) { return }

        let review = await reviewer.run(
            AgentReviewRequest(
                job: job,
                workspace: Workspace(root: workspaceURL),
                files: files,
                rules: rules,
                newWork: newWork,
                isCancelled: {
                    (try? await store.job(id: jobID))?.status.isTerminal ?? true
                }
            )
        )
        if try await stopped(jobID) { return }
        if !review.findings.isEmpty {
            try await store.insertParsedFindings(review.findings)
        }
        if review.failed {
            _ = try await store.apply(
                jobID: jobID,
                event: .reviewFailed(review.errorMessage ?? "reviewer_failed"),
                errorMessage: review.errorMessage ?? "reviewer_failed"
            )
            try await store.appendEvent(jobID: jobID, level: .error, message: "review_failed")
            return
        }
        _ = try await store.apply(
            jobID: jobID,
            event: .reviewOK(validFindingCount: review.findings.count)
        )
        if let after = try await store.job(id: jobID), after.status == .judging {
            _ = try await store.apply(jobID: jobID, event: .judgeFinished)
        }
        try await store.appendEvent(jobID: jobID, level: .info, message: "succeeded")
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
