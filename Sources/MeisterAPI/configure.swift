import Foundation
import Vapor

func configure(_ app: Application) async throws {
    let config = try MeisterConfig.load()
    try await configure(app, config: config)
}

func configure(_ app: Application, config: MeisterConfig) async throws {
    try BindPolicy.requireLoopbackOrAllowRemote(
        bind: config.bind,
        allowRemote: BindPolicy.allowRemoteFromEnvironment()
    )

    app.meisterConfig = config
    app.http.server.configuration.hostname = config.bind
    app.http.server.configuration.port = config.port

    try FileManager.default.createDirectory(
        atPath: config.dataDir,
        withIntermediateDirectories: true
    )

    let publicDirectory = spaPublicDirectory(workingDirectory: app.directory.workingDirectory)
    if FileManager.default.fileExists(atPath: publicDirectory) {
        app.middleware.use(FileMiddleware(publicDirectory: publicDirectory))
    }

    app.get("api", "health") { _ in
        HealthDTO(ok: true, version: MeisterVersion.current)
    }

    app.get("api", "settings") { req in
        req.application.meisterConfig.settingsDTO
    }

    // Client routes like /jobs/:id are not files; serve the SPA shell.
    app.get("**") { req async throws -> Response in
        if req.url.path == "/api" || req.url.path.hasPrefix("/api/") {
            throw Abort(.notFound)
        }
        let index = publicDirectory + "index.html"
        guard FileManager.default.fileExists(atPath: index) else {
            throw Abort(.notFound)
        }
        return try await req.fileio.asyncStreamFile(at: index)
    }
}

func spaPublicDirectory(workingDirectory: String) -> String {
    var root = workingDirectory
    if !root.hasSuffix("/") {
        root.append("/")
    }
    return root + "frontend/dist/"
}
