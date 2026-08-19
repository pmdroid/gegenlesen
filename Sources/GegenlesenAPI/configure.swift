import Foundation
import GegenlesenAgent
import GegenlesenCore
import Vapor

func configure(_ app: Application) async throws {
    let config = try GegenlesenConfig.load()
    try await configure(app, config: config)
}

func configure(
    _ app: Application,
    config: GegenlesenConfig,
    allowRemote: Bool? = nil,
    docker: (any DockerExecuting)? = nil,
    startQueue: Bool = true,
    skipAgent: Bool? = nil,
    embedder: (any EmbeddingClient)? = nil
) async throws {
    try BindPolicy.requireLoopbackOrAllowRemote(
        bind: config.bind,
        allowRemote: allowRemote ?? BindPolicy.allowRemoteFromEnvironment()
    )

    JSONCoding.install()

    app.gegenlesenConfig = config
    app.http.server.configuration.hostname = config.bind
    app.http.server.configuration.port = config.port

    let maxBody = config.limits.archiveBytes + 1_048_576
    app.routes.defaultMaxBodySize = ByteCount(value: maxBody)

    app.middleware = .init()
    app.middleware.use(APIErrorMiddleware())

    let dataDir = URL(fileURLWithPath: config.dataDir, isDirectory: true)
    app.gegenlesenStore = try Store.open(dataDir: dataDir)

    app.gegenlesenDocker = docker ?? DockerRunner()
    let skip = skipAgent ?? (ProcessInfo.processInfo.environment["GEGENLESEN_SKIP_AGENT"] == "1")
    if let runner = app.gegenlesenDocker as? DockerRunner {
        do {
            try runner.ensureEgressNetwork()
        } catch {
            if !skip { throw error }
        }
    }
    let resolvedEmbedder = embedder ?? EmbeddingClientFactory.fromEnvironment(
        model: config.embeddings.model,
        dimensions: config.embeddings.dimensions
    )
    app.gegenlesenEmbedder = resolvedEmbedder
    let runtime = JobRuntime(
        store: app.gegenlesenStore,
        config: config,
        logger: app.logger,
        docker: app.gegenlesenDocker,
        skipAgent: skip,
        workingDirectory: app.directory.workingDirectory,
        embedder: resolvedEmbedder
    )
    app.gegenlesenJobs = runtime
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
    }.run(store: app.gegenlesenStore, docker: app.gegenlesenDocker, jobs: runtime)

    let publicDirectory = spaPublicDirectory(workingDirectory: app.directory.workingDirectory)
    if FileManager.default.fileExists(atPath: publicDirectory) {
        app.middleware.use(
            FileMiddleware(publicDirectory: publicDirectory, defaultFile: "index.html")
        )
    }

    app.get("api", "health") { _ in
        HealthDTO(ok: true, version: GegenlesenVersion.current)
    }

    app.get("api", "settings") { req in
        req.application.gegenlesenConfig.settingsDTO
    }

    let rulesDir = URL(fileURLWithPath: app.directory.workingDirectory, isDirectory: true)
        .appendingPathComponent("rules", isDirectory: true)
    _ = try await RuleSeeder.upsertAbsent(from: rulesDir, into: app.gegenlesenStore)

    JobsRoute.register(app)
    FindingsRoute.register(app)
    RulesRoute.register(app)
    CorpusRoute.register(app)
    ContextRoute.register(app)
    LearningsRoute.register(app)
    MetricsRoute.register(app)

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

private struct GegenlesenStoreKey: StorageKey {
    typealias Value = Store
}

private struct GegenlesenEmbedderBox: Sendable {
    var client: (any EmbeddingClient)?
}

private struct GegenlesenEmbedderKey: StorageKey {
    typealias Value = GegenlesenEmbedderBox
}

extension Application {
    var gegenlesenStore: Store {
        get {
            guard let value = storage[GegenlesenStoreKey.self] else {
                fatalError("Store missing; call configure(_:config:) first")
            }
            return value
        }
        set { storage[GegenlesenStoreKey.self] = newValue }
    }

    var gegenlesenEmbedder: (any EmbeddingClient)? {
        get { storage[GegenlesenEmbedderKey.self]?.client }
        set { storage[GegenlesenEmbedderKey.self] = GegenlesenEmbedderBox(client: newValue) }
    }
}
