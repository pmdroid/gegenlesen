import Testing
@testable import GegenlesenCore

@Suite
struct PathGlobTests {
    @Test
    func lastMatchingLineWins() {
        let includeThenExclude = PathGlob(["**/*", "!**/*.md"])
        #expect(includeThenExclude.matches("Sources/A.swift"))
        #expect(!includeThenExclude.matches("README.md"))

        let excludeThenInclude = PathGlob(["!**/*.md", "**/*"])
        #expect(excludeThenInclude.matches("README.md"))
        #expect(excludeThenInclude.matches("Sources/A.swift"))
    }

    @Test
    func starDoesNotCrossSlash() {
        #expect(PathGlob(["*.swift"]).matches("App.swift"))
        #expect(PathGlob(["*.swift"]).matches("Sources/App.swift"))
        #expect(!PathGlob(["Sources/*.swift"]).matches("Sources/Nested/App.swift"))
        #expect(PathGlob(["Sources/**/*.swift"]).matches("Sources/Nested/App.swift"))
    }

    @Test
    func doubleStarAndQuestion() {
        #expect(PathGlob(["**/*.ts"]).matches("a/b/c.ts"))
        #expect(PathGlob(["src/?.go"]).matches("src/a.go"))
        #expect(!PathGlob(["src/?.go"]).matches("src/ab.go"))
        #expect(!PathGlob(["src/?.go"]).matches("src/a/b.go"))
    }

    @Test
    func trailingSlashIsDirectoriesOnly() {
        #expect(PathGlob(["src/"]).matches("src/main.swift"))
        #expect(!PathGlob(["src/"]).matches("src"))
        #expect(PathGlob(["src/"]).matches("src", isDirectory: true))
    }

    @Test
    func braceExpansion() {
        let glob = PathGlob(["**/*.{swift,md}"])
        #expect(glob.matches("A.swift"))
        #expect(glob.matches("docs/A.md"))
        #expect(!glob.matches("A.go"))
    }

    @Test
    func defaultIgnoresVendorAndBinaries() {
        #expect(PathGlob.defaultIgnores.matches("node_modules/pkg/index.js"))
        #expect(PathGlob.defaultIgnores.matches(".git/HEAD"))
        #expect(PathGlob.defaultIgnores.matches("dist/app.js"))
        #expect(PathGlob.defaultIgnores.matches("logo.png"))
        #expect(PathGlob.defaultIgnores.matches("Package.resolved"))
        #expect(!PathGlob.defaultIgnores.matches("Sources/App.swift"))
    }
}