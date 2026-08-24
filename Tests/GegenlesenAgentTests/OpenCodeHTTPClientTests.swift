import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GegenlesenAgent
@testable import GegenlesenCore

@Suite
struct OpenCodeHTTPClientTests {
    @Test
    func classifies401BodyAsProviderAuth() {
        let body = Data(#"{"error":{"message":"User not found.","code":401}}"#.utf8)
        let error = OpenCodeHTTPError.classify(status: 401, body: body)
        guard case .providerAuth(let status, let snippet) = error else {
            Issue.record("expected providerAuth")
            return
        }
        #expect(status == 401)
        #expect(snippet.contains("User not found"))
        #expect(String(describing: error).contains("provider_auth"))
    }

    @Test
    func classifies403StatusAsProviderAuth() {
        let error = OpenCodeHTTPError.classify(status: 403, body: Data(#"{"error":"forbidden"}"#.utf8))
        guard case .providerAuth(let status, _) = error else {
            Issue.record("expected providerAuth")
            return
        }
        #expect(status == 403)
    }

    @Test
    func classifies200ErrorEventBodyAsProviderAuth() {
        let body = Data(#"{"type":"error","error":{"message":"User not found.","code":401}}"#.utf8)
        let error = OpenCodeHTTPError.classify(status: 200, body: body)
        guard case .providerAuth(let status, _) = error else {
            Issue.record("expected providerAuth from body")
            return
        }
        #expect(status == 401)
    }

    @Test
    func ignoresHealthyAndMissingFindingsBodies() {
        #expect(OpenCodeHTTPError.classify(status: 200, body: Data(#"{"healthy":true}"#.utf8)) == nil)
        #expect(OpenCodeHTTPError.classify(status: 500, body: Data("reviewer_no_findings_file".utf8)) == nil)
    }
}
