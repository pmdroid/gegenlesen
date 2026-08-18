import Foundation
import MeisterCore
import Vapor

func configure(_ app: Application) async throws {
    let config = try MeisterConfig.load()
    try await configure(app, config: config)
}

func configure(
    _ app: Application,
    config: MeisterConfig,
    allowRemote: Bool? = nil
) async throws {
    try BindPolicy.requireLoopbackOrAllowRemote(
        bind: config.bind,
        allowRemote: allowRemote ?? BindPolicy.allowRemoteFromEnvironment()
    )

    app.meisterConfig = config
    app.http.server.configuration.hostname = config.bind
    app.http.server.configuration.port = config.port

    let dataDir = URL(fileURLWithPath: config.dataDir, isDirectory: true)
    app.meisterStore = try Store.open(dataDir: dataDir)

    let publicDirectory = spaPublicDirectory(workingDirectory: app.directory.workingDirectory)
    if FileManager.default.fileExists(atPath: publicDirectory) {
        app.middleware.use(
            FileMiddleware(publicDirectory: publicDirectory, defaultFile: "index.html")
        )
    }

    app.get("api", "health") { _ in
        HealthDTO(ok: true, version: MeisterVersion.current)
    }

    app.get("api", "settings") { req in
        req.application.meisterConfig.settingsDTO
    }

    // RoutingKit does not match `/` against a lone `**`, so register the empty path too.
    let spa: @Sendable (Request) async throws -> Response = { req in
        try await serveSPAIndex(req, publicDirectory: publicDirectory)
    }
    app.get(use: spa)
    app.get("**", use: spa)
}

func serveSPAIndex(_ req: Request, publicDirectory: String) async throws -> Response {
    if req.url.path == "/api" || req.url.path.hasPrefix("/api/") {
        throw Abort(.notFound)
    }
    let index = publicDirectory + "index.html"
    guard FileManager.default.fileExists(atPath: index) else {
        throw Abort(.notFound)
    }
    return try await req.fileio.asyncStreamFile(at: index)
}

func spaPublicDirectory(workingDirectory: String) -> String {
    var root = workingDirectory
    if !root.hasSuffix("/") {
        root.append("/")
    }
    return root + "frontend/dist/"
}

private struct MeisterStoreKey: StorageKey {
    typealias Value = Store
}

extension Application {
    var meisterStore: Store {
        get {
            guard let value = storage[MeisterStoreKey.self] else {
                fatalError("Store missing; call configure(_:config:) first")
            }
            return value
        }
        set { storage[MeisterStoreKey.self] = newValue }
    }
}
