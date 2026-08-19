import Crypto
import Foundation
import Testing
@testable import GegenlesenCore

@Suite
struct ContentHashTests {
    @Test
    func hashesFileBytesNotGitBlobSHA1() throws {
        try withTempDir("gegenlesen-hash") { dir in
            let url = dir.appendingPathComponent("hello.txt")
            let bytes = Data("hello\n".utf8)
            try bytes.write(to: url)

            let digest = try ContentHash.sha256(fileAt: url)
            #expect(digest == ContentHash.sha256(bytes))
            #expect(digest == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")

            let git = try runIsolated(
                executable: "/usr/bin/git",
                arguments: ["hash-object", url.path],
                cwd: dir
            )
            let gitBlob = String(data: git.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(gitBlob == "ce013625030ba8dba906f756967f9e9ca394464a")
            #expect(digest != gitBlob)
        }
    }

    @Test
    func matchesSHA256Directly() {
        let data = Data("gegenlesen".utf8)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(ContentHash.sha256(data) == expected)
    }
}
