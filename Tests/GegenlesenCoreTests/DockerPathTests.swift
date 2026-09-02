import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct DockerPathTests {
    @Test
    func overrideEnvWins() {
        #expect(
            DockerPath.resolve(environment: ["GEGENLESEN_DOCKER": "/opt/custom/docker"])
                == "/opt/custom/docker"
        )
    }

    @Test
    func searchesPathWhenWellKnownMissing() throws {
        try withTempDir("docker-path") { dir in
            let binary = dir.appendingPathComponent("docker")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: binary.path
            )
            let resolved = DockerPath.resolve(
                environment: ["PATH": dir.path],
                wellKnown: []
            )
            #expect(resolved == binary.path)
        }
    }

    @Test
    func dockerCLIArgumentsOmitNprocUnlessSet() {
        let base = DockerRequest(
            name: "c",
            image: "img",
            pidsLimit: 256,
            ulimitNofile: "1024:1024"
        )
        let args = base.dockerCLIArguments()
        #expect(args.contains("--pids-limit"))
        #expect(args.contains("256"))
        #expect(args.contains("nofile=1024:1024"))
        #expect(!args.contains { $0.contains("nproc=") })

        let capped = DockerRequest(
            name: "c",
            image: "img",
            pidsLimit: 256,
            ulimitNproc: "256:256",
            ulimitNofile: "1024:1024"
        )
        let cappedArgs = capped.dockerCLIArguments()
        #expect(cappedArgs.contains("nproc=256:256"))
        #expect(cappedArgs.contains("--pids-limit"))
    }
}
