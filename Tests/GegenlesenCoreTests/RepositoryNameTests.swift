import Testing
@testable import GegenlesenCore

@Suite
struct RepositoryNameTests {
    @Test
    func normalizesRemotesAndPaths() {
        #expect(RepositoryName.normalize("git@github.com:acme/meister.git") == "github.com/acme/meister")
        #expect(RepositoryName.normalize("https://github.com/acme/meister.git") == "github.com/acme/meister")
        #expect(RepositoryName.normalize("  ") == nil)
        #expect(RepositoryName.normalize(nil) == nil)
    }

    @Test
    func globalItemsAlwaysApply() {
        #expect(RepositoryName.applies(nil, to: "github.com/acme/meister"))
        #expect(RepositoryName.applies(nil, to: nil))
        #expect(!RepositoryName.applies("github.com/acme/other", to: "github.com/acme/meister"))
        #expect(RepositoryName.applies("github.com/acme/meister", to: "github.com/acme/meister"))
        #expect(!RepositoryName.applies("github.com/acme/meister", to: nil))
    }
}
