import Foundation

public struct ReviewPipeline: Sendable {
    public var store: Store
    public var skipAgent: Bool
    public var identifyTimeout: Duration
    public var deterministicTimeout: Duration
    public var deterministic: (any DeterministicRunning)?
    public var reviewer: (any ReviewerRunning)?
    public var judge: (any JudgeRunning)?
    public var ruleTokenBudget: Int
    public var retrieveK: Int
    public var embedder: (any EmbeddingClient)?

    public init(
        store: Store,
        skipAgent: Bool = true,
        identifyTimeout: Duration = .seconds(60),
        deterministicTimeout: Duration = .seconds(30),
        deterministic: (any DeterministicRunning)? = nil,
        reviewer: (any ReviewerRunning)? = nil,
        judge: (any JudgeRunning)? = nil,
        ruleTokenBudget: Int = 6000,
        retrieveK: Int = 12,
        embedder: (any EmbeddingClient)? = nil
    ) {
        self.store = store
        self.skipAgent = skipAgent
        self.identifyTimeout = identifyTimeout
        self.deterministicTimeout = deterministicTimeout
        self.deterministic = deterministic
        self.reviewer = reviewer
        self.judge = judge
        self.ruleTokenBudget = ruleTokenBudget
        self.retrieveK = retrieveK
        self.embedder = embedder
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

        var parentFiles: [JobFile] = []
        var parentFindings: [Finding] = []
        var interdiffEmpty = false
        var incrementalScope = false
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
            var changeSet = try identifier.identify()
            let job = try await store.job(id: jobID)
            if job?.scope == .incremental {
                incrementalScope = true
                let incremental = try await resolveIncremental(
                    job: job,
                    identified: changeSet,
                    workspaceURL: workspaceURL,
                    jobID: jobID
                )
                changeSet = incremental.changeSet
                parentFiles = incremental.parentFiles
                parentFindings = incremental.parentFindings
                interdiffEmpty = changeSet.files.isEmpty
            }
            try await store.replaceJobFiles(changeSet.files)
            try await store.appendEvent(
                jobID: jobID,
                level: .info,
                message: interdiffEmpty ? "interdiff_empty" : "identified"
            )
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
        let workspace = Workspace(root: workspaceURL)
        do {
            try await ArchitectureIndexJob(
                store: store,
                embedder: embedder,
                skipAgent: skipAgent
            ).run(workspace: workspace, jobID: jobID)
        } catch {
            try await store.appendEvent(
                jobID: jobID,
                level: .warning,
                message: "architecture_index_failed"
            )
        }
        if try await stopped(jobID) { return }

        let rules: [Rule]
        do {
            rules = try await selectAndPack(
                jobID: jobID,
                files: files,
                workspace: workspace
            )
            try await store.appendEvent(
                jobID: jobID,
                level: .info,
                message: "selecting_rules",
                payloadJSON: #"{"count":\#(rules.count)}"#
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

        let workspace = Workspace(root: workspaceURL)
        let matcher = FindingMatcher(jobID: jobID)
        let carried = incrementalScope
            ? matcher.carryForward(
                parent: parentFindings,
                parentFiles: parentFiles,
                child: ChangeSet(
                    baseSHA: "",
                    headSHA: "",
                    patchRelativePath: "",
                    files: files,
                    source: .hashInterdiff
                ),
                workspace: workspace
            )
            : []
        let remaining = remainingFiles(
            interdiff: files,
            parentFiles: parentFiles,
            jobID: jobID,
            workspace: workspace
        )
        try await store.appendEvent(jobID: jobID, level: .info, message: "deterministic")
        let result: DeterministicRunResult
        if let deterministic {
            result = await deterministic.run(
                files: remaining,
                workspace: workspace,
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

        let carriedParents = Set(carried.compactMap(\.parentFindingID))
        var unmatchedDet = 0
        var detFindings: [Finding] = []
        let now = Date()
        for draft in result.drafts {
            var finding = finding(from: draft, jobID: jobID, now: now)
            if let collapsed = matcher.collapse(
                child: finding,
                parents: parentFindings,
                childFiles: files,
                parentFiles: parentFiles
            ), let parentID = collapsed.parentFindingID, carriedParents.contains(parentID) {
                continue
            } else if let collapsed = matcher.collapse(
                child: finding,
                parents: parentFindings,
                childFiles: files,
                parentFiles: parentFiles
            ) {
                finding = collapsed
            } else {
                unmatchedDet += 1
            }
            detFindings.append(finding)
        }

        let persist = carried + detFindings
        if !persist.isEmpty {
            try await store.insertParsedFindings(persist)
        }

        let newWork = !files.isEmpty || unmatchedDet > 0
        let skipReviewer = skipAgent || !newWork
        _ = try await store.apply(
            jobID: jobID,
            event: .deterministicDone(newWork: newWork, skipAgent: skipReviewer)
        )
        try await store.appendEvent(
            jobID: jobID,
            level: .info,
            message: skipReviewer ? "succeeded" : "reviewing"
        )
        if skipReviewer { return }
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
                workspace: workspace,
                files: files,
                rules: rules,
                parentFindings: parentFindings,
                newWork: newWork,
                isCancelled: {
                    (try? await store.job(id: jobID))?.status.isTerminal ?? true
                }
            )
        )
        if try await stopped(jobID) { return }
        let reviewFindings = review.findings.compactMap { finding -> Finding? in
            let collapsed = matcher.collapse(
                child: finding,
                parents: parentFindings,
                childFiles: files,
                parentFiles: parentFiles
            ) ?? finding
            if let parentID = collapsed.parentFindingID, carriedParents.contains(parentID) {
                return nil
            }
            return collapsed
        }
        if !reviewFindings.isEmpty {
            try await store.insertParsedFindings(reviewFindings)
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

        let workspace = Workspace(root: workspaceURL)
        let commandIDs = JudgeMerge.commandRuleIDs(from: rules)
        let stored = try await store.findings(jobID: jobID)
        let mechanical = JudgeHandoff.stampMechanical(stored, commandRuleIDs: commandIDs)
        let candidates = JudgeHandoff.prepareCandidates(
            stored,
            commandRuleIDs: commandIDs,
            workspace: workspace
        )
        JudgeHandoff.persistAgentBlob(workspace: workspace, blobs: store.blobs, jobID: jobID)
        let input = JudgeHandoff.inputFile(from: candidates, workspace: workspace)
        let wroteInput: Bool
        do {
            try JudgeHandoff.writeInput(input, workspace: workspace, blobs: store.blobs, jobID: jobID)
            wroteInput = true
        } catch {
            wroteInput = false
        }

        if candidates.isEmpty {
            try await store.updateFindings(mechanical)
            _ = try await store.apply(
                jobID: jobID,
                event: .reviewOK(validFindingCount: 0)
            )
            try await store.appendEvent(jobID: jobID, level: .info, message: "succeeded")
            return
        }

        _ = try await store.apply(
            jobID: jobID,
            event: .reviewOK(validFindingCount: candidates.count)
        )
        if try await stopped(jobID) { return }

        try await store.updateJobContainers(jobID: jobID, containerName: judgeName)
        let outcome: JudgeOutcome
        if wroteInput, let judge {
            let judged = await judge.run(
                JudgeRequest(
                    job: job,
                    workspace: workspace,
                    isCancelled: {
                        (try? await store.job(id: jobID))?.status.isTerminal ?? true
                    }
                )
            )
            JudgeHandoff.persistTranscript(judged.transcript, blobs: store.blobs, jobID: jobID)
            outcome = judged.outcome
        } else if wroteInput {
            outcome = .containerFailed
        } else {
            // No judge-input on disk — merge locally so !evidence_ok still drops.
            outcome = .verdicts(JudgeFile(verdicts: []))
        }
        if try await stopped(jobID) { return }

        let merged = JudgeMerge.merge(candidates: candidates, judge: outcome)
        let byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        let persisted = mechanical.map { finding in
            byID[finding.id] ?? finding
        }
        try await store.updateFindings(persisted)
        JudgeHandoff.persistPostJudge(persisted, blobs: store.blobs, jobID: jobID)
        _ = try await store.apply(jobID: jobID, event: .judgeFinished)
        try await store.appendEvent(jobID: jobID, level: .info, message: "succeeded")
    }

    private func resolveIncremental(
        job: Job?,
        identified: ChangeSet,
        workspaceURL: URL,
        jobID: JobID
    ) async throws -> (changeSet: ChangeSet, parentFiles: [JobFile], parentFindings: [Finding]) {
        guard let job, let parentID = job.parentJobID else {
            throw IdentifyError(errorMessage: "incremental requires parent_job_id")
        }
        guard let parent = try await store.job(id: parentID),
              parent.status == .succeeded,
              let parentHead = nonempty(parent.headSHA),
              nonempty(parent.baseSHA) != nil
        else {
            throw IdentifyError(errorMessage: "parent_job_id must reference a succeeded job with base_sha, head_sha, and job_files")
        }
        let parentFiles = try await store.jobFiles(id: parentID)
        guard !parentFiles.isEmpty else {
            throw IdentifyError(errorMessage: "parent_job_id must reference a succeeded job with base_sha, head_sha, and job_files")
        }
        let parentFindings = try await store.findings(jobID: parentID)
        let parentWS = store.blobs.workspaceURL(jobID: parentID.rawValue)
        let parentWorkspace = FileManager.default.fileExists(atPath: parentWS.path) ? parentWS : nil
        let changeSet = try IncrementalDiff.compute(
            identified: identified,
            workspace: workspaceURL,
            blobs: store.blobs,
            jobID: jobID,
            parentHeadSHA: parentHead,
            parentFiles: parentFiles,
            parentWorkspace: parentWorkspace,
            timeout: identifyTimeout
        )
        return (changeSet, parentFiles, parentFindings)
    }

    private func remainingFiles(
        interdiff: [JobFile],
        parentFiles: [JobFile],
        jobID: JobID,
        workspace: Workspace
    ) -> [JobFile] {
        if !interdiff.isEmpty {
            return interdiff.filter { $0.status != .deleted }
        }
        return parentFiles.compactMap { file in
            guard file.status != .deleted else { return nil }
            guard workspace.resolveForRead(file.path) != nil else { return nil }
            var copy = file
            copy.jobID = jobID
            return copy
        }
    }

    private func finding(from draft: FindingDraft, jobID: JobID, now: Date) -> Finding {
        Finding(
            id: FindingID.generate(at: now),
            jobID: jobID,
            ruleID: draft.ruleID,
            phase: draft.phase,
            severity: draft.severity,
            title: draft.title,
            message: draft.message,
            filePath: draft.filePath,
            startLine: draft.startLine,
            endLine: draft.endLine,
            snippet: draft.snippet,
            agentRationale: draft.rationale,
            confidence: draft.confidence,
            lifecycle: .new,
            suggestedPatch: draft.suggestedPatch,
            fingerprint: Fingerprint.sha256(ruleID: draft.ruleID, path: draft.filePath, snippet: draft.snippet),
            createdAt: now
        )
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func selectAndPack(
        jobID: JobID,
        files: [JobFile],
        workspace: Workspace
    ) async throws -> [Rule] {
        let enabled = try await store.listRules(RuleListFilter(enabled: true))
        let job = try await store.job(id: jobID)
        let patch = loadPatchText(jobID: jobID, workspace: workspace)
        let tokens = RetrievalQuery.tokens(
            paths: files.map(\.path),
            patch: patch,
            title: job?.title
        )
        let ftsQuery = RetrievalQuery.ftsQuery(tokens: tokens)
        let ftsScores = (try? await store.ftsBM25Scores(query: ftsQuery)) ?? [:]
        let selected = RuleSelector().select(rules: enabled, files: files, ftsScores: ftsScores)
        let deterministic = selected.filter { !$0.rule.payload.isSemantic }.map(\.rule)
        let semantic = selected.filter { $0.rule.payload.isSemantic }.map(\.rule)
        let budgeted = PromptBudget(tokenBudget: ruleTokenBudget).apply(semantic)
        try await writeContextPack(
            jobID: jobID,
            files: files,
            workspace: workspace,
            title: job?.title,
            patch: patch
        )
        return deterministic + budgeted
    }

    private func writeContextPack(
        jobID: JobID,
        files: [JobFile],
        workspace: Workspace,
        title: String?,
        patch: Data?
    ) async throws {
        let notes = try await store.listContextNotes()
        var hits: [ContextRetrieveHit] = []
        let queryText = RetrievalQuery.tokens(paths: files.map(\.path), patch: patch, title: title)
            .joined(separator: " ")
        if let embedder {
            do {
                if let vector = try await embedder.embed([queryText]).first {
                    hits = try await store.retrieveChunks(query: vector, k: retrieveK)
                }
            } catch {
                try await store.appendEvent(
                    jobID: jobID,
                    level: .warning,
                    message: "embedding_failed"
                )
            }
        }
        if hits.isEmpty {
            let always = notes.filter(\.alwaysInclude)
            if !always.isEmpty {
                for note in always {
                    hits.append(
                        contentsOf: (try? await store.chunks(
                            kind: note.kind == .architecture ? .architecture : .user,
                            ref: note.id
                        ))?.map { ContextRetrieveHit(chunk: $0, score: 1) } ?? []
                    )
                }
            }
        }
        try ContextPack.write(workspace: workspace, notes: notes, hits: hits)
    }

    private func loadPatchText(jobID: JobID, workspace: Workspace) -> Data? {
        if let multipart = loadMultipartPatch(jobID: jobID) { return multipart }
        let embedded = workspace.root.appendingPathComponent(".meister/diff.patch")
        guard FileManager.default.fileExists(atPath: embedded.path) else { return nil }
        return try? Data(contentsOf: embedded)
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
