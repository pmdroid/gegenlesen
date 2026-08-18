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
    allowRemote: Bool? = nil,
    docker: (any DockerExecuting)? = nil,
    startQueue: Bool = true,
    skipAgent: Bool? = nil
) async throws {
    try BindPolicy.requireLoopbackOrAllowRemote(
        bind: config.bind,
        allowRemote: allowRemote ?? BindPolicy.allowRemoteFromEnvironment()
    )

    JSONCoding.install()

    app.meisterConfig = config
    app.http.server.configuration.hostname = config.bind
    app.http.server.configuration.port = config.port

    let maxBody = config.limits.archiveBytes + 1_048_576
    app.routes.defaultMaxBodySize = ByteCount(value: maxBody)

    app.middleware = .init()
    app.middleware.use(APIErrorMiddleware())

    let dataDir = URL(fileURLWithPath: config.dataDir, isDirectory: true)
    app.meisterStore = try Store.open(dataDir: dataDir)

    app.meisterDocker = docker ?? DockerCLI()
    let skip = skipAgent ?? (ProcessInfo.processInfo.environment["MEISTER_SKIP_AGENT"] == "1")
    let runtime = JobRuntime(
        store: app.meisterStore,
        config: config,
        logger: app.logger,
        docker: app.meisterDocker,
        skipAgent: skip,
        workingDirectory: app.directory.workingDirectory
    )
    app.meisterJobs = runtime
    app.lifecycle.use(JobRuntimeLifecycle())
    if startQueue {
        runtime.start()
    }

    await BootReconcile { message, metadata in
        var md = Logger.Metadata()
        for (key, value) in metadata {
            md[key] = .string(value)
        }
        app.logger.info(.init(stringLiteral: message), metadata: md)
    }.run(store: app.meisterStore, docker: app.meisterDocker, jobs: runtime)

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

    let rulesDir = URL(fileURLWithPath: app.directory.workingDirectory, isDirectory: true)
        .appendingPathComponent("rules", isDirectory: true)
    _ = try await RuleSeeder.upsertAbsent(from: rulesDir, into: app.meisterStore)

    JobsRoute.register(app)
    RulesRoute.register(app)

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
