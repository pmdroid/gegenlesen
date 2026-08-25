import Foundation
import Vapor

enum AgentsRoute {
    static func register(_ app: Application) {
        app.get("api", "agents", use: list)
        app.get("api", "agents", ":id", use: show)
        app.put("api", "agents", ":id", use: update)
        app.post("api", "agents", ":id", "reset", use: reset)
        app.post("api", "agents", ":id", "improve", use: improve)
    }

    private static func list(_ req: Request) throws -> AgentListDTO {
        let store = agentStore(req)
        return AgentListDTO(
            agents: try store.list(),
            minerModel: req.application.gegenlesenConfig.minerModel
        )
    }

    private static func show(_ req: Request) throws -> AgentDTO {
        try agentStore(req).get(id(req))
    }

    private static func update(_ req: Request) async throws -> AgentDTO {
        let body = try req.content.decode(AgentUpdate.self)
        return try agentStore(req).put(id(req), prompt: body.prompt)
    }

    private static func reset(_ req: Request) throws -> AgentDTO {
        try agentStore(req).reset(id(req))
    }

    private static func improve(_ req: Request) async throws -> AgentImproveResponse {
        let agentID = try id(req)
        let body = try req.content.decode(AgentImproveRequest.self)
        let instruction = body.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            throw APIError.unprocessable("instruction is required")
        }
        guard instruction.count <= AgentCatalog.maxInstructionChars else {
            throw APIError.payloadTooLarge("instruction is too long")
        }
        let store = agentStore(req)
        let current: String
        if let draft = body.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty {
            current = draft
        } else {
            current = try store.get(agentID).prompt
        }
        let model = req.application.gegenlesenConfig.minerModel
        let improved = try await req.application.gegenlesenPromptImprover.improve(
            model: model,
            currentPrompt: current,
            instruction: instruction
        )
        return AgentImproveResponse(prompt: improved)
    }

    private static func id(_ req: Request) throws -> String {
        guard let raw = req.parameters.get("id") else {
            throw APIError.notFound("unknown agent")
        }
        return try AgentCatalog.requireID(raw)
    }

    private static func agentStore(_ req: Request) -> AgentStore {
        AgentStore(
            workingDirectory: req.application.directory.workingDirectory,
            dataDir: req.application.gegenlesenConfig.dataDir
        )
    }
}
