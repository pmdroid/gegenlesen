import ArgumentParser
import Foundation
import Vapor

@main
struct MeisterAPI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "MeisterAPI",
        abstract: "Meister HTTP API",
        subcommands: [Serve.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the Meister HTTP API"
    )

    @ArgumentParser.Option(name: .long, help: "Bind address (loopback unless MEISTER_ALLOW_REMOTE=1).")
    var bind: String?

    @ArgumentParser.Option(name: .long, help: "Listen port.")
    var port: Int?

    @ArgumentParser.Option(name: .long, help: "Data directory for sqlite and blobs.")
    var dataDir: String?

    func run() async throws {
        var config = try MeisterConfig.load()
        if let bind { config.bind = bind }
        if let port { config.port = port }
        if let dataDir { config.dataDir = dataDir }

        var env = Environment(
            name: ProcessInfo.processInfo.environment["VAPOR_ENV"] ?? "production",
            arguments: [
                "MeisterAPI",
                "serve",
                "--hostname", config.bind,
                "--port", String(config.port),
            ]
        )
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        do {
            try await configure(app, config: config)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
