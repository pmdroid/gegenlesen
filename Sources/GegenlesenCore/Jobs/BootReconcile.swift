import Foundation

public struct BootReconcile: Sendable {
    public var log: (@Sendable (String, [String: String]) -> Void)?

    public init(log: (@Sendable (String, [String: String]) -> Void)? = nil) {
        self.log = log
    }

    public func run(
        store: Store,
        docker: DockerExecuting,
        jobs: ReviewJobQueuing
    ) async {
        await docker.removeAll(prefix: "gegenlesen-")

        let failed: Int
        do {
            failed = try await store.failProcessRestarted()
        } catch {
            log?("boot reconcile fail-in-flight failed", ["error": "\(error)"])
            return
        }

        let queued: [JobID]
        do {
            queued = try await store.queuedUnstartedIDs()
        } catch {
            log?("boot reconcile list queued failed", ["error": "\(error)"])
            return
        }

        var requeued = 0
        for id in queued {
            do {
                if FileManager.default.fileExists(atPath: store.blobs.mineSpecURL(jobID: id.rawValue).path) {
                    try await jobs.pushMine(id)
                } else {
                    try await jobs.pushReview(id)
                }
                requeued += 1
            } catch {
                log?("boot reconcile requeue failed", ["job_id": id.rawValue, "error": "\(error)"])
            }
        }

        log?("boot reconcile", ["failed": "\(failed)", "requeued": "\(requeued)"])
    }
}
