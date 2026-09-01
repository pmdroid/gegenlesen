import Foundation
import GegenlesenAgent
import GegenlesenCore
import Vapor

extension EngineModelDTO: Content {}
extension EngineModelList: Content {}

enum EngineModelsRoute {
    static func register(_ app: Application) {
        app.get("api", "engines", ":engine", "models", use: list)
    }

    private static func list(_ req: Request) async throws -> EngineModelList {
        let raw = try req.parameters.require("engine")
        let engine = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentEngineID.isKnown(engine) else {
            throw APIError.badRequest("unknown engine: \(engine)")
        }
        if engine == AgentEngineID.opencode {
            throw APIError.badRequest("use /api/models for OpenCode")
        }
        if req.application.gegenlesenJobs.skipAgent {
            return EngineModelList(engine: engine, models: [], source: "disabled")
        }
        let config = req.application.gegenlesenConfig
        let providerEnv = config.providerEnv(from: ProcessInfo.processInfo.environment)
        let root = gegenlesenPackageRoot()
        do {
            return try await ACPModelProbe.listModels(
                engine: engine,
                packageRoot: root,
                providerEnv: providerEnv
            )
        } catch ACPModelProbeError.engineNotConfigured(let id) {
            throw APIError.unprocessable("\(id) auth not configured — CLI login or API key required")
        } catch ACPModelProbeError.unsupportedEngine(let id) {
            throw APIError.badRequest("engine \(id) does not support ACP model listing")
        } catch ACPModelProbeError.scriptMissing {
            throw APIError.unprocessable("ACP model probe script missing (set GEGENLESEN_ROOT)")
        } catch ACPModelProbeError.probeFailed(let message) {
            throw APIError.unprocessable("could not list \(engine) models via ACP: \(message)")
        }
    }
}
