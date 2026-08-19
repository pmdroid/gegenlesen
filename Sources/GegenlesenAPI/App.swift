import ArgumentParser
import Foundation
import Vapor

@main
struct GegenlesenAPI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "GegenlesenAPI",
        abstract: "gegenlesen HTTP API",
        subcommands: [Serve.self],
        defaultSubcommand: Serve.self
    )
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the gegenlesen HTTP API"
    )

    @ArgumentParser.Option(name: .long, help: "Bind address (loopback unless GEGENLESEN_ALLOW_REMOTE=1).")
    var bind: String?

    @ArgumentParser.Option(name: .long, help: "Listen port.")
    var port: Int?

    @ArgumentParser.Option(name: .long, help: "Data directory for sqlite and blobs.")
    var dataDir: String?

    func run() async throws {
        var loaded = try GegenlesenConfig.loadDetailed()
        if let bind { loaded.config.bind = bind }
        if let port { loaded.config.port = port }
        if let dataDir { loaded.config.dataDir = dataDir }

        var env = Environment(
            name: ProcessInfo.processInfo.environment["VAPOR_ENV"] ?? "production",
            arguments: [
                "GegenlesenAPI",
                "serve",
                "--hostname", loaded.config.bind,
                "--port", String(loaded.config.port),
            ]
        )
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        do {
            try await configure(app, config: loaded.config, configFileURL: loaded.fileURL)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
