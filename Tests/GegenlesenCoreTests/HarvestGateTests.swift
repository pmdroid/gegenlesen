import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct HarvestGateTests {
    @Test
    func unresolvedRepositoryFailsClosed() {
        #expect(throws: HarvestGateError.repositoryUnresolved) {
            try HarvestGate.check(repository: nil, hasSucceededHarvest: false)
        }
        #expect(throws: HarvestGateError.repositoryUnresolved) {
            try HarvestGate.check(repository: "  ", hasSucceededHarvest: true)
        }
    }

    @Test
    func missingSucceededHarvestFailsClosed() {
        #expect(throws: HarvestGateError.harvestRequired) {
            try HarvestGate.check(repository: "github.com/acme/app", hasSucceededHarvest: false)
        }
    }

    @Test
    func succeededHarvestPasses() throws {
        try HarvestGate.check(repository: "github.com/acme/app", hasSucceededHarvest: true)
    }

    @Test
    func storeCountsOnlySucceededHarvestJobs() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            let repo = "github.com/acme/app"
            #expect(try await store.hasSucceededHarvest(repository: repo) == false)

            var failed = sampleJob(id: "harvest-failed", status: .failed, finishedAt: now)
            failed.title = "harvest tree.tar.gz"
            failed.repository = repo
            failed.errorMessage = "harvest_judge_failed"
            try await store.insertJob(failed)
            #expect(try await store.hasSucceededHarvest(repository: repo) == false)

            var other = sampleJob(id: "review-1", status: .succeeded, finishedAt: now)
            other.title = "fix hop"
            other.repository = repo
            try await store.insertJob(other)
            #expect(try await store.hasSucceededHarvest(repository: repo) == false)

            var ok = sampleJob(id: "harvest-ok", status: .succeeded, finishedAt: now)
            ok.title = "harvest tree.tar.gz"
            ok.repository = repo
            try await store.insertJob(ok)
            #expect(try await store.hasSucceededHarvest(repository: repo) == true)
            #expect(try await store.hasSucceededHarvest(repository: "github.com/other/app") == false)
        }
    }
}
