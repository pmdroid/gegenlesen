import Foundation
import GegenlesenCore
import Testing
import VaporTesting
@testable import GegenlesenAPI

@Suite
struct HealthTests {
    @Test
    func health() async throws {
        try await withGegenlesenApp { app in
            try await app.testing().test(.GET, "/api/health") { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(HealthDTO.self)
                #expect(body == HealthDTO(ok: true, version: GegenlesenVersion.current))
            }
        }
    }

    @Test
    func configureOpensSQLiteStore() async throws {
        try await withGegenlesenApp { app in
            let identifiers = try await app.gegenlesenStore.appliedMigrationIdentifiers()
            #expect(identifiers == [Migrations.v1Initial, Migrations.v2Repositories, Migrations.v3Risk])
            #expect(!(try await app.gegenlesenStore.tableExists("settings")))
        }
    }

    @Test
    func settingsFromExampleConfig() async throws {
        try await withGegenlesenApp { app in
            try await app.testing().test(.GET, "/api/settings") { res async throws in
                #expect(res.status == .ok)
                let settings = try res.content.decode(SettingsDTO.self)
                let expected = GegenlesenConfig.example.settingsDTO(environment: [:])
                #expect(settings.bind == expected.bind)
                #expect(settings.port == expected.port)
                #expect(settings.models == expected.models)
                #expect(settings.judgeModel == expected.judgeModel)
                #expect(settings.minerModel == expected.minerModel)
                #expect(settings.opencodeImage == expected.opencodeImage)
                #expect(settings.limits == expected.limits)
                #expect(!res.body.string.contains("API_KEY"))
                #expect(!res.body.string.contains("openrouter_api_key"))
                #expect(!res.body.string.contains("data_dir"))
            }
        }
    }

    @Test
    func refuseNonLoopbackBind() async throws {
        try await withApp { app in
            var config = GegenlesenConfig.example
            config.bind = "0.0.0.0"
            await #expect(throws: BindRefused.remote("0.0.0.0")) {
                try await configure(app, config: config, allowRemote: false)
            }
        }
    }

    @Test
    func spaFallbackServesIndex() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("gegenlesen-spa-\(UUID().uuidString)")
        let dist = tmp.appendingPathComponent("frontend/dist")
        try fm.createDirectory(at: dist, withIntermediateDirectories: true)
        try "<html>ledger</html>".write(
            to: dist.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fm.removeItem(at: tmp) }

        try await withGegenlesenApp(workingDirectory: tmp.path) { app in
            try await app.testing().test(.GET, "/") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("ledger"))
            }
            try await app.testing().test(.GET, "/jobs/demo") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("ledger"))
            }
            try await app.testing().test(.GET, "/api/missing") { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}

func withGegenlesenApp(
    workingDirectory: String? = nil,
    configFileURL: URL? = nil,
    mutate: (inout GegenlesenConfig) -> Void = { _ in },
    startQueue: Bool = false,
    docker: any DockerExecuting = NoopDocker(),
    promptImprover: (any PromptImproving)? = FakePromptImprover(),
    _ body: (Application) async throws -> Void
) async throws {
    let dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("gegenlesen-api-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dataDir) }
    try await withApp { app in
        if let workingDirectory {
            app.directory.workingDirectory = workingDirectory.hasSuffix("/")
                ? workingDirectory
                : workingDirectory + "/"
        }
        var config = GegenlesenConfig.example
        config.dataDir = dataDir.path
        mutate(&config)
        try await configure(
            app,
            config: config,
            docker: docker,
            startQueue: startQueue,
            skipAgent: true,
            embedder: HashEmbeddingClient(),
            configFileURL: configFileURL,
            promptImprover: promptImprover
        )
        try await body(app)
    }
}

struct FakePromptImprover: PromptImproving {
    var result: String?

    func improve(model: String, currentPrompt: String, instruction: String) async throws -> String {
        if let result { return result }
        return currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\nIMPROVED:\n\(instruction)\n"
    }
}
