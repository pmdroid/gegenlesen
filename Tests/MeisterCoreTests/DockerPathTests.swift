import Foundation
import Testing
@testable import MeisterCore

@Suite
struct DockerPathTests {
    @Test
    func overrideEnvWins() {
        #expect(
            DockerPath.resolve(environment: ["MEISTER_DOCKER": "/opt/custom/docker"])
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
}
