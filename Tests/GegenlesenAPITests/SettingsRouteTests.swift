import Foundation
import Testing
import VaporTesting
@testable import GegenlesenAPI

@Suite
struct SettingsRouteTests {
    @Test
    func putRejectsAppetiteOutOfRange() async throws {
        try await withGegenlesenApp(mutate: { $0.openrouterApiKey = "sk-or-test" }) { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: nil,
                        judgeModel: nil,
                        openrouterApiKey: nil,
                        risk: RiskSettingsUpdate(mode: nil, appetite: 9)
                    ))
                }
            ) { res async throws in
                #expect(res.status == .unprocessableEntity)
            }
        }
    }

    @Test
    func putPersistsAppetite() async throws {
        try await withGegenlesenApp(mutate: { $0.openrouterApiKey = "sk-or-test" }) { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: nil,
                        judgeModel: nil,
                        openrouterApiKey: nil,
                        risk: RiskSettingsUpdate(mode: .shadow, appetite: 3)
                    ))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let settings = try res.content.decode(SettingsDTO.self)
                #expect(settings.risk.appetite == 3)
                #expect(settings.risk.mode == .shadow)
            }
        }
    }

    @Test
    func putRejectsBlankModels() async throws {
        try await withGegenlesenApp { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: ModelSlots(modelA: "  ", modelB: "openrouter/google/gemini-3.7-flash"),
                        judgeModel: nil,
                        openrouterApiKey: nil,
                        scannerImage: nil
                    ))
                }
            ) { res async throws in
                #expect(res.status == .unprocessableEntity)
            }
        }
    }

    @Test
    func putPersistsModelsAndKeyWithoutEchoingSecret() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gegenlesen-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("gegenlesen.json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await withGegenlesenApp(configFileURL: file) { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: ModelSlots(
                            modelA: "openrouter/custom/a",
                            modelB: "openrouter/custom/b"
                        ),
                        judgeModel: "openrouter/custom/judge",
                        openrouterApiKey: "sk-or-test-onboarding",
                        scannerImage: nil
                    ))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let settings = try res.content.decode(SettingsDTO.self)
                #expect(settings.models.modelA == "openrouter/custom/a")
                #expect(settings.models.modelB == "openrouter/custom/b")
                #expect(settings.judgeModel == "openrouter/custom/judge")
                #expect(settings.minerModel == GegenlesenConfig.example.minerModel)
                #expect(settings.openrouterConfigured)
                #expect(!res.body.string.contains("sk-or-test-onboarding"))
                #expect(!res.body.string.contains("openrouter_api_key"))
            }

            try await app.testing().test(.GET, "/api/settings") { res async throws in
                #expect(res.status == .ok)
                let settings = try res.content.decode(SettingsDTO.self)
                #expect(settings.openrouterConfigured)
                #expect(!res.body.string.contains("sk-or-test-onboarding"))
            }

            let saved = try JSONDecoder().decode(GegenlesenConfig.self, from: Data(contentsOf: file))
            #expect(saved.openrouterApiKey == "sk-or-test-onboarding")
            #expect(saved.models.modelA == "openrouter/custom/a")
            #expect(app.gegenlesenJobs.config.models.modelA == "openrouter/custom/a")
        }
    }

    @Test
    func putPersistsMinerModel() async throws {
        try await withGegenlesenApp(mutate: { $0.openrouterApiKey = "sk-or-test" }) { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: nil,
                        judgeModel: nil,
                        minerModel: "openrouter/custom/miner",
                        openrouterApiKey: nil
                    ))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let settings = try res.content.decode(SettingsDTO.self)
                #expect(settings.minerModel == "openrouter/custom/miner")
                #expect(settings.judgeModel == GegenlesenConfig.example.judgeModel)
            }
            #expect(app.gegenlesenJobs.config.minerModel == "openrouter/custom/miner")
        }
    }

    @Test
    func putRejectsBlankMinerModel() async throws {
        try await withGegenlesenApp(mutate: { $0.openrouterApiKey = "sk-or-test" }) { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: nil,
                        judgeModel: nil,
                        minerModel: "   ",
                        openrouterApiKey: nil
                    ))
                }
            ) { res async throws in
                #expect(res.status == .unprocessableEntity)
            }
        }
    }

    @Test
    func putPersistsMineTimeout() async throws {
        try await withGegenlesenApp(mutate: { $0.openrouterApiKey = "sk-or-test" }) { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: nil,
                        judgeModel: nil,
                        openrouterApiKey: nil,
                        limits: LimitsSettingsUpdate(mineTimeoutSec: 14_400, agentTimeoutSec: 1_200)
                    ))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let settings = try res.content.decode(SettingsDTO.self)
                #expect(settings.limits.mineTimeoutSec == 14_400)
                #expect(settings.limits.agentTimeoutSec == 1_200)
            }
            #expect(app.gegenlesenJobs.config.limits.mineTimeoutSec == 14_400)
            #expect(app.gegenlesenJobs.config.limits.agentTimeoutSec == 1_200)
        }
    }

    @Test
    func putPersistsLearnInterval() async throws {
        try await withGegenlesenApp(mutate: { $0.openrouterApiKey = "sk-or-test" }) { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: nil,
                        judgeModel: nil,
                        openrouterApiKey: nil,
                        limits: LimitsSettingsUpdate(learnIntervalMinutes: 180)
                    ))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let settings = try res.content.decode(SettingsDTO.self)
                #expect(settings.limits.learnIntervalMinutes == 180)
            }
            #expect(app.gegenlesenJobs.config.limits.learnIntervalMinutes == 180)
        }
    }

    @Test
    func putPersistsScannerImageIncludingBlank() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gegenlesen-scanner-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("gegenlesen.json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        try await withGegenlesenApp(configFileURL: file) { app in
            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: nil,
                        judgeModel: nil,
                        openrouterApiKey: "sk-or-test-onboarding",
                        scannerImage: "  myorg/checks:1  "
                    ))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let settings = try res.content.decode(SettingsDTO.self)
                #expect(settings.scannerImage == "myorg/checks:1")
            }
            #expect(app.gegenlesenJobs.config.scannerImage == "myorg/checks:1")

            try await app.testing().test(
                .PUT,
                "/api/settings",
                beforeRequest: { req async throws in
                    try req.content.encode(SettingsUpdate(
                        models: nil,
                        judgeModel: nil,
                        openrouterApiKey: nil,
                        scannerImage: "   "
                    ))
                }
            ) { res async throws in
                #expect(res.status == .ok)
                let settings = try res.content.decode(SettingsDTO.self)
                #expect(settings.scannerImage == "")
            }
            let saved = try JSONDecoder().decode(GegenlesenConfig.self, from: Data(contentsOf: file))
            #expect(saved.scannerImage == "")
            #expect(app.gegenlesenJobs.config.scannerImage == "")
        }
    }
}
