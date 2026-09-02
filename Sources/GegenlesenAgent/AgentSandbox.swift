import Foundation
import GegenlesenCore

public struct AgentContainerPayload: Sendable {
    public var image: String
    public var argv: [String]
    public var env: [String: String]
    public var tmpfs: [String]
    public var binds: [DockerRequest.Bind]

    public init(
        image: String,
        argv: [String],
        env: [String: String] = [:],
        tmpfs: [String] = [],
        binds: [DockerRequest.Bind] = []
    ) {
        self.image = image
        self.argv = argv
        self.env = env
        self.tmpfs = tmpfs
        self.binds = binds
    }
}

public enum AgentSandbox {
    static let homeTmpfs = [
        "/tmp:rw,nosuid,nodev,uid=1000,gid=1000,size=512m",
        "/home/gegenlesen/.local:rw,nosuid,nodev,uid=1000,gid=1000,size=256m",
        "/home/gegenlesen/.cache:rw,nosuid,nodev,uid=1000,gid=1000,size=64m",
    ]

    static let providerKeys = [
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "OPENROUTER_API_KEY",
        "CODEX_API_KEY",
        "CURSOR_API_KEY",
        "CURSOR_AUTH_TOKEN",
        "XAI_API_KEY",
        "GROK_API_KEY",
    ]

    public static func dockerRequest(
        name: String,
        payload: AgentContainerPayload,
        workspace: URL,
        providerEnv: [String: String],
        cpus: String,
        memory: String,
        timeout: Duration,
        ulimitNproc: String? = nil
    ) -> DockerRequest {
        var env = payload.env
        env["HOME"] = "/home/gegenlesen"
        env["XDG_CACHE_HOME"] = "/home/gegenlesen/.cache"
        for key in providerKeys {
            if let value = providerEnv[key], !value.isEmpty {
                env[key] = value
            }
        }
        return DockerRequest(
            name: name,
            image: payload.image,
            argv: payload.argv,
            env: env,
            network: "gegenlesen-egress",
            workdir: "/workspace",
            publishLoopback: nil,
            user: "1000:1000",
            readOnly: true,
            tmpfs: homeTmpfs + payload.tmpfs,
            binds: [DockerRequest.Bind(source: workspace.path, dest: "/workspace", readOnly: false)] + payload.binds,
            cpus: cpus,
            memory: memory,
            pidsLimit: 256,
            capDropAll: true,
            noNewPrivileges: true,
            ulimitNproc: ulimitNproc,
            ulimitNofile: "1024:1024",
            timeout: timeout,
            injectProviderKeys: true,
            remove: true,
            passThroughEnv: providerKeys
        )
    }
}
