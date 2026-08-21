import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct RulePromotionTests {
    @Test
    func collapseDropsHarvestTwinAfterPromoteCopy() async throws {
        try await withTempDataDir { dir in
            let store = try Store.open(dataDir: dir)
            let now = Date()
            try await store.insertRule(
                Rule(
                    id: RuleID("harvest-follow-standard-entity-id-format-guidelines"),
                    title: "Follow standard entity ID format guidelines",
                    severity: .warning,
                    kind: .semantic,
                    enabled: false,
                    provenance: .harvest,
                    languages: ["*"],
                    pathGlobs: ["**/*"],
                    payload: .semantic(instruction: "use guids", fewShots: []),
                    createdAt: now,
                    updatedAt: now
                )
            )
            try await store.insertRule(
                Rule(
                    id: RuleID("harvest-follow-standard-entity-id-format-guidelines-handwritten"),
                    title: "Follow standard entity ID format guidelines",
                    severity: .warning,
                    kind: .semantic,
                    enabled: true,
                    provenance: .handwritten,
                    languages: ["*"],
                    pathGlobs: ["**/*"],
                    payload: .semantic(instruction: "use guids", fewShots: []),
                    promotedFromRuleID: RuleID("harvest-follow-standard-entity-id-format-guidelines"),
                    createdAt: now,
                    updatedAt: now
                )
            )
            let removed = try await RulePromotion.collapseDuplicates(into: store)
            #expect(removed >= 1)
            let kept = try await store.listRules(RuleListFilter(includeDeleted: false))
            #expect(kept.count == 1)
            #expect(kept[0].provenance == .handwritten)
            #expect(kept[0].enabled)
        }
    }
}
