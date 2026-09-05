import Foundation

public struct ReviewPipeline: Sendable {
    public var store: Store
    public var skipAgent: Bool
    public var identifyTimeout: Duration
    public var deterministicTimeout: Duration
    public var scannerTimeout: Duration
    public var deterministic: (any DeterministicRunning)?
    public var scanner: (any ScannerRunning)?
    public var reviewer: (any ReviewerRunning)?
    public var judge: (any JudgeRunning)?
    public var ruleTokenBudget: Int
    public var retrieveK: Int
    public var maxChunks: Int
    public var embedder: (any EmbeddingClient)?
    public var miner: (any MinerRunning)?
    public var learnEngine: String
    public var learnModel: String
    public var reviewStrictMode: Bool
    public var risk: RiskConfig
    public var requireHarvest: Bool

    public init(
        store: Store,
        skipAgent: Bool = true,
        identifyTimeout: Duration = .seconds(60),
        deterministicTimeout: Duration = .seconds(30),
        scannerTimeout: Duration = .seconds(120),
        deterministic: (any DeterministicRunning)? = nil,
        scanner: (any ScannerRunning)? = nil,
        reviewer: (any ReviewerRunning)? = nil,
        judge: (any JudgeRunning)? = nil,
        ruleTokenBudget: Int = 6000,
        retrieveK: Int = 12,
        maxChunks: Int = 20_000,
        embedder: (any EmbeddingClient)? = nil,
        miner: (any MinerRunning)? = nil,
        learnEngine: String = AgentEngineID.opencode,
        learnModel: String = "openrouter/openai/gpt-5.6-terra",
        reviewStrictMode: Bool = false,
        risk: RiskConfig = .v1,
        requireHarvest: Bool = false
    ) {
        self.store = store
        self.skipAgent = skipAgent
        self.identifyTimeout = identifyTimeout
        self.deterministicTimeout = deterministicTimeout
        self.scannerTimeout = scannerTimeout
        self.deterministic = deterministic
        self.scanner = scanner
        self.reviewer = reviewer
        self.judge = judge
        self.ruleTokenBudget = ruleTokenBudget
        self.retrieveK = retrieveK
        self.maxChunks = maxChunks
        self.embedder = embedder
        self.miner = miner ?? (reviewer as? any MinerRunning)
        self.learnEngine = learnEngine
        self.learnModel = learnModel
        self.reviewStrictMode = reviewStrictMode
        self.risk = risk
        self.requireHarvest = requireHarvest
    }

    public func run(jobID: JobID) async throws {
        do {
            try await runPhases(jobID: jobID)
        } catch is JobStateMachine.IllegalTransition {
            return
        } catch let error as StoreJobError where error == .notFound {
            return
        } catch {
            let message = String(describing: error)
            _ = try? await store.finishJob(id: jobID, status: .failed, errorMessage: message)
            try? await store.appendEvent(jobID: jobID, level: .error, message: "internal")
        }
    }

    private func runPhases(jobID: JobID) async throws {
        guard let existing = try await store.job(id: jobID) else { return }
        if existing.status.isTerminal { return }

        try await store.appendEvent(jobID: jobID, level: .info, message: "dequeued")
        _ = try await store.apply(jobID: jobID, event: .dequeued)
        if try await stopped(jobID) { return }

        var timings = JobTimings()
        let workspaceURL = store.blobs.workspaceURL(jobID: jobID.rawValue)
        let archive = store.blobs.archiveURL(jobID: jobID.rawValue)
        let unpackStarted = ContinuousClock.now
        do {
            try ArchiveUnpacker().unpack(archive: archive, into: workspaceURL)
            try await recordTiming(\.unpackMS, from: unpackStarted, jobID: jobID, timings: &timings)
            try await store.appendEvent(jobID: jobID, level: .info, message: "unpacked")
            _ = try await store.apply(jobID: jobID, event: .unpackOK)
            try await fillRepositoryIfNeeded(jobID: jobID, workspace: workspaceURL)
        } catch {
            try await recordTiming(\.unpackMS, from: unpackStarted, jobID: jobID, timings: &timings)
            _ = try await store.apply(
                jobID: jobID,
                event: .unpackFailed(String(describing: error)),
                errorMessage: String(describing: error)
            )
            try await store.appendEvent(
                jobID: jobID,
                level: .error,
                message: "unpack_failed",
                payloadJSON: JobEvent.payloadJSON(["message": String(describing: error)])
            )
            return
        }
        if try await stopped(jobID) { return }

        var parentFiles: [JobFile] = []
        var parentFindings: [Finding] = []
        var interdiffEmpty = false
        var incrementalScope = false
        var changeSource: ChangeSet.Source?
        var patchBytes: Data?
        let identifyStarted = ContinuousClock.now
        do {
            let meta = loadIdentifyMeta(jobID: jobID)
            let patch = loadMultipartPatch(jobID: jobID)
            patchBytes = patch
            let identifier = ChangeSetIdentifier(
                workspace: workspaceURL,
                blobs: store.blobs,
                jobID: jobID,
                meta: meta,
                multipartPatch: patch,
                timeout: identifyTimeout
            )
            var changeSet = try identifier.identify()
            if let wide = PackSignals.evaluate(
                changeSet: changeSet,
                workspace: workspaceURL,
                timeout: identifyTimeout
            ) {
                try await store.appendEvent(
                    jobID: jobID,
                    level: .warning,
                    message: "wide_pack_base",
                    payloadJSON: JobEvent.payloadJSON([
                        "base": wide.base,
                        "base_source": wide.baseSource ?? "unknown",
                        "pack_files": wide.packFiles,
                        "head_own_files": wide.headOwnFiles,
                    ])
                )
            }
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
            changeSource = changeSet.source
            try await store.replaceJobFiles(changeSet.files)
            try await recordTiming(\.identifyMS, from: identifyStarted, jobID: jobID, timings: &timings)
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
            try await recordTiming(\.identifyMS, from: identifyStarted, jobID: jobID, timings: &timings)
            _ = try await store.apply(
                jobID: jobID,
                event: .identifyFailed(error.errorMessage),
                errorMessage: error.errorMessage
            )
            try await store.appendEvent(
                jobID: jobID,
                level: .error,
                message: error.errorMessage,
                payloadJSON: JobEvent.payloadJSON(["message": error.errorMessage])
            )
            return
        } catch {
            try await recordTiming(\.identifyMS, from: identifyStarted, jobID: jobID, timings: &timings)
            _ = try await store.apply(
                jobID: jobID,
                event: .identifyFailed("no_change_set"),
                errorMessage: "no_change_set"
            )
            try await store.appendEvent(
                jobID: jobID,
                level: .error,
                message: "no_change_set",
                payloadJSON: JobEvent.payloadJSON(["message": String(describing: error)])
            )
            return
        }
        if try await stopped(jobID) { return }

        if requireHarvest, try await failClosedWithoutHarvest(jobID: jobID) {
            return
        }
        if try await stopped(jobID) { return }

        let files = try await store.jobFiles(id: jobID)
        let workspace = Workspace(root: workspaceURL)
        patchBytes = loadPatchText(jobID: jobID, workspace: workspace)
        do {
            let indexer = ArchitectureIndexJob(
                store: store,
                embedder: embedder,
                maxChunks: maxChunks,
                skipAgent: skipAgent,
                miner: miner,
                engine: learnEngine,
                model: learnModel,
                onWarning: { [store, jobID] message in
                    try? await store.appendEvent(jobID: jobID, level: .warning, message: message)
                },
                onInfo: { [store, jobID] message in
                    try? await store.appendEvent(jobID: jobID, level: .info, message: message)
                }
            )
            try await indexer.run(workspace: workspace, jobID: jobID)
            try await indexer.embedEnabledRules(try await store.listRules(RuleListFilter(enabled: true)))
        } catch {
            try await store.appendEvent(
                jobID: jobID,
                level: .warning,
                message: "architecture_index_failed",
                payloadJSON: JobEvent.payloadJSON(["message": String(describing: error)])
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
            try await store.appendEvent(
                jobID: jobID,
                level: .error,
                message: "rules_failed",
                payloadJSON: JobEvent.payloadJSON(["message": String(describing: error)])
            )
            return
        }
        if try await stopped(jobID) { return }

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
        let deterministicStarted = ContinuousClock.now
        var result: DeterministicRunResult
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
            try await recordTiming(\.deterministicMS, from: deterministicStarted, jobID: jobID, timings: &timings)
            _ = try await store.apply(jobID: jobID, event: .deterministicTimeout)
            try await store.appendEvent(
                jobID: jobID,
                level: .error,
                message: "deterministic_timeout",
                payloadJSON: JobEvent.payloadJSON(["message": "deterministic_timeout"])
            )
            return
        }
        if let scanner {
            try await store.appendEvent(jobID: jobID, level: .info, message: "scanning")
            let scan = await scanner.run(
                jobID: jobID,
                files: remaining,
                workspace: workspace,
                timeout: scannerTimeout,
                isCancelled: { [store, jobID] in
                    (try? await store.job(id: jobID))?.status.isTerminal ?? true
                }
            )
            if try await stopped(jobID) { return }
            result = DeterministicRunResult(
                drafts: result.drafts + scan.drafts,
                timedOut: false,
                warnings: result.warnings + scan.warnings
            )
        }
        try await recordTiming(\.deterministicMS, from: deterministicStarted, jobID: jobID, timings: &timings)
        if try await stopped(jobID) { return }
        for warning in result.warnings {
            try await store.appendEvent(
                jobID: jobID,
                level: .warning,
                message: warning.message,
                payloadJSON: warning.payloadJSON
            )
        }

        let carriedParents = Set(carried.compactMap { (finding: Finding) in finding.parentFindingID })
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

        let persist = try await applyOperatorSuppressions(carried + detFindings, jobID: jobID)
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
        if skipReviewer {
            try await persistRisk(
                jobID: jobID,
                source: changeSource,
                files: files,
                rules: rules,
                patch: patchBytes,
                reviewersInvoked: false,
                validReviewerFiles: 0,
                judgeUnavailable: false
            )
            return
        }
        if try await stopped(jobID) { return }

        guard let job = try await store.job(id: jobID) else { return }
        guard let reviewer else {
            try await failReview(
                jobID: jobID,
                errorClass: .reviewerFailed,
                errorMessage: "reviewer_unavailable",
                payloadJSON: JobEvent.payloadJSON([
                    "error_class": ReviewFailureClass.reviewerFailed.rawValue,
                    "message": "reviewer_unavailable",
                ])
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

        let reviewStarted = ContinuousClock.now
        let review = await reviewer.run(
            AgentReviewRequest(
                job: job,
                workspace: workspace,
                files: files,
                rules: rules,
                parentFindings: parentFindings,
                newWork: newWork,
                reviewStrictMode: reviewStrictMode,
                isCancelled: {
                    (try? await store.job(id: jobID))?.status.isTerminal ?? true
                }
            )
        )
        try await recordTiming(\.reviewMS, from: reviewStarted, jobID: jobID, timings: &timings)
        if try await stopped(jobID) { return }
        if review.reviewDegraded,
           let slot = review.reviewDegradedSlot,
           let engine = review.reviewDegradedEngine,
           let error = review.reviewDegradedError
        {
            try await store.updateJobReviewDegraded(
                jobID: jobID,
                slot: slot,
                engine: engine,
                error: error
            )
            try await store.appendEvent(
                jobID: jobID,
                level: .warning,
                message: "review_degraded",
                payloadJSON: JobEvent.payloadJSON([
                    "slot": slot,
                    "engine": engine,
                    "error": error,
                ])
            )
        }
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
        let suppressedReview = try await applyOperatorSuppressions(reviewFindings, jobID: jobID)
        if !suppressedReview.isEmpty {
            try await store.insertParsedFindings(suppressedReview)
        }
        if review.failed {
            let detail = review.errorMessage ?? ReviewFailureClass.reviewerFailed.rawValue
            let errorClass = ReviewFailureClass.classify(
                errorMessage: detail,
                payloadJSON: review.payloadJSON
            )
            try await failReview(
                jobID: jobID,
                errorClass: errorClass,
                errorMessage: detail,
                payloadJSON: review.payloadJSON ?? JobEvent.payloadJSON([
                    "error_class": errorClass.rawValue,
                    "message": detail,
                ])
            )
            return
        }

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
            try await persistRisk(
                jobID: jobID,
                source: changeSource,
                files: files,
                rules: rules,
                patch: patchBytes,
                reviewersInvoked: true,
                validReviewerFiles: review.validFileCount,
                judgeUnavailable: false
            )
            return
        }

        _ = try await store.apply(
            jobID: jobID,
            event: .reviewOK(validFindingCount: candidates.count)
        )
        if try await stopped(jobID) { return }

        try await store.updateJobContainers(jobID: jobID, containerName: judgeName)
        let judgeStarted = ContinuousClock.now
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
        try await recordTiming(\.judgeMS, from: judgeStarted, jobID: jobID, timings: &timings)
        if try await stopped(jobID) { return }

        let merged = JudgeMerge.merge(candidates: candidates, judge: outcome)
        let byID = Dictionary(uniqueKeysWithValues: merged.map { (finding: Finding) in (finding.id, finding) })
        let persisted = mechanical.map { finding in
            byID[finding.id] ?? finding
        }
        let labeled = try await applyOperatorSuppressions(persisted, jobID: jobID)
        try await store.updateFindings(labeled)
        JudgeHandoff.persistPostJudge(labeled, blobs: store.blobs, jobID: jobID)
        _ = try await store.apply(jobID: jobID, event: .judgeFinished)
        try await store.appendEvent(jobID: jobID, level: .info, message: "succeeded")
        try await persistRisk(
            jobID: jobID,
            source: changeSource,
            files: files,
            rules: rules,
            patch: patchBytes,
            reviewersInvoked: true,
            validReviewerFiles: review.validFileCount,
            judgeUnavailable: RiskGate.judgeDidNotRun(wroteInput: wroteInput, outcome: outcome)
        )
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

    private func applyOperatorSuppressions(_ findings: [Finding], jobID: JobID) async throws -> [Finding] {
        guard !findings.isEmpty else { return findings }
        let repository = try await store.job(id: jobID)?.repository
        guard let repository, RepositoryName.normalize(repository) != nil else { return findings }
        let suppressed = try await store.suppressedFingerprints(repository: repository)
        guard !suppressed.isEmpty else { return findings }
        return findings.map { OperatorSuppression.apply($0, suppressed: suppressed) }
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
            judgeVerdict: draft.requiresJudge ? nil : .keep,
            confidence: draft.confidence,
            lifecycle: .new,
            suggestedPatch: draft.suggestedPatch,
            fingerprint: Fingerprint.sha256(ruleID: draft.ruleID, path: draft.filePath, snippet: draft.snippet),
            evidenceOK: draft.requiresJudge ? draft.evidenceOK : true,
            createdAt: now
        )
    }

    private func fillRepositoryIfNeeded(jobID: JobID, workspace: URL) async throws {
        guard let job = try await store.job(id: jobID), job.repository == nil else { return }
        guard let detected = RepositoryName.detectPackedOrRemote(in: workspace) else { return }
        try await store.updateJobRepository(id: jobID, repository: detected)
    }

    /// Returns true when the job was failed closed.
    private func failClosedWithoutHarvest(jobID: JobID) async throws -> Bool {
        let repo = try await store.job(id: jobID)?.repository
        let harvested: Bool
        if let repo {
            harvested = try await store.hasSucceededHarvest(repository: repo)
        } else {
            harvested = false
        }
        do {
            try HarvestGate.check(repository: repo, hasSucceededHarvest: harvested)
            return false
        } catch let error as HarvestGateError {
            let message = error.description
            _ = try await store.apply(
                jobID: jobID,
                event: .rulesFailed(message),
                errorMessage: message
            )
            try await store.appendEvent(jobID: jobID, level: .error, message: message)
            return true
        }
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
        let job = try await store.job(id: jobID)
        var filter = RuleListFilter.applicable(to: job?.repository)
        filter.enabled = true
        let enabled = try await store.listRules(filter)
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
        let job = try await store.job(id: jobID)
        let notes = try await store.listContextNotes(
            repository: job?.repository,
            unscoped: job?.repository == nil,
            includeGlobal: job?.repository != nil
        )
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
                    message: "embedding_failed",
                    payloadJSON: JobEvent.payloadJSON(["message": String(describing: error)])
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
        let visibleNotes = notes.filter { note in
            noteApplies(note, to: files.map(\.path))
        }
        let visibleHits = hits.filter { hit in
            if hit.chunk.kind == .file { return true }
            if hit.chunk.kind == .rule {
                return true
            }
            guard let note = notes.first(where: { $0.id == hit.chunk.ref }) else { return false }
            return noteApplies(note, to: files.map(\.path))
        }
        try ContextPack.write(workspace: workspace, notes: visibleNotes, hits: visibleHits)
    }

    private func noteApplies(_ note: ContextNote, to paths: [String]) -> Bool {
        if note.alwaysInclude { return true }
        if note.pathGlobs.isEmpty { return true }
        let matcher = PathGlob(note.pathGlobs)
        return paths.contains { matcher.matches($0) }
    }

    private func loadPatchText(jobID: JobID, workspace: Workspace) -> Data? {
        if let multipart = loadMultipartPatch(jobID: jobID) { return multipart }
        let embedded = workspace.root.appendingPathComponent(".gegenlesen/diff.patch")
        guard FileManager.default.fileExists(atPath: embedded.path) else { return nil }
        return try? Data(contentsOf: embedded)
    }

    private func stopped(_ jobID: JobID) async throws -> Bool {
        try await store.job(id: jobID)?.status.isTerminal ?? true
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let ms = (ContinuousClock.now - start).timeInterval * 1000
        return max(0, Int(ms.rounded()))
    }

    private func recordTiming(
        _ keyPath: WritableKeyPath<JobTimings, Int?>,
        from start: ContinuousClock.Instant,
        jobID: JobID,
        timings: inout JobTimings
    ) async throws {
        timings[keyPath: keyPath] = milliseconds(since: start)
        try await store.updateJobTimings(jobID: jobID, timings: timings)
    }

    private func failReview(
        jobID: JobID,
        errorClass: ReviewFailureClass,
        errorMessage: String,
        payloadJSON: String?
    ) async throws {
        _ = try await store.apply(
            jobID: jobID,
            event: .reviewFailed(errorClass.rawValue),
            errorMessage: errorClass.rawValue
        )
        try await store.appendEvent(
            jobID: jobID,
            level: .error,
            message: "review_failed",
            payloadJSON: payloadJSON
        )
        try await persistCompactFailureRisk(
            jobID: jobID,
            errorClass: errorClass,
            detail: errorMessage
        )
    }

    private func persistCompactFailureRisk(
        jobID: JobID,
        errorClass: ReviewFailureClass,
        detail: String
    ) async throws {
        let assessment = RiskAssessment(
            verdict: .needsHuman,
            mode: risk.mode,
            score: 5,
            appetite: risk.appetite,
            reasons: [
                RiskReason(code: errorClass.rawValue, detail: detail),
            ]
        )
        try await store.updateJobRisk(jobID: jobID, assessment: assessment)
        try await store.appendEvent(
            jobID: jobID,
            level: .info,
            message: "risk_\(assessment.verdict.rawValue)"
        )
    }

    private func persistRisk(
        jobID: JobID,
        source: ChangeSet.Source?,
        files: [JobFile],
        rules: [Rule],
        patch: Data?,
        reviewersInvoked: Bool,
        validReviewerFiles: Int,
        judgeUnavailable: Bool
    ) async throws {
        guard let job = try await store.job(id: jobID) else { return }
        let findings = try await store.findings(jobID: jobID)
        var filter = RuleListFilter.applicable(to: job.repository)
        filter.enabled = true
        let enabled = try await store.listRules(filter)
        let assessment = RiskGate.evaluate(
            RiskGate.Input(
                scope: job.scope,
                changeSetSource: source,
                files: files,
                findings: findings,
                rules: enabled,
                changedLines: RiskGate.changedLines(in: patch),
                reviewersInvoked: reviewersInvoked,
                validReviewerFiles: validReviewerFiles,
                judgeUnavailable: judgeUnavailable,
                config: risk
            )
        )
        try await store.updateJobRisk(jobID: jobID, assessment: assessment)
        try await store.appendEvent(
            jobID: jobID,
            level: .info,
            message: "risk_\(assessment.verdict.rawValue)"
        )
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
