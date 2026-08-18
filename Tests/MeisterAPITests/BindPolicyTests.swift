import Testing
@testable import MeisterAPI

@Suite
struct BindPolicyTests {
    @Test
    func loopbackAddresses() {
        #expect(BindPolicy.isLoopback("127.0.0.1"))
        #expect(BindPolicy.isLoopback("127.0.0.2"))
        #expect(BindPolicy.isLoopback("localhost"))
        #expect(BindPolicy.isLoopback("::1"))
        #expect(BindPolicy.isLoopback("[::1]"))
        #expect(BindPolicy.isLoopback(" 127.0.0.1 "))
    }

    @Test
    func nonLoopbackAddresses() {
        #expect(!BindPolicy.isLoopback("0.0.0.0"))
        #expect(!BindPolicy.isLoopback("::"))
        #expect(!BindPolicy.isLoopback("192.168.1.10"))
        #expect(!BindPolicy.isLoopback(""))
        #expect(!BindPolicy.isLoopback("127.0.0.256"))
    }

    @Test
    func refuseRemoteWithoutOverride() {
        #expect(throws: BindRefused.remote("0.0.0.0")) {
            try BindPolicy.requireLoopbackOrAllowRemote(bind: "0.0.0.0", allowRemote: false)
        }
    }

    @Test
    func allowRemoteWithOverride() throws {
        try BindPolicy.requireLoopbackOrAllowRemote(bind: "0.0.0.0", allowRemote: true)
    }

    @Test
    func allowRemoteEnvIsStrictOne() {
        #expect(BindPolicy.allowRemoteFromEnvironment(["MEISTER_ALLOW_REMOTE": "1"]))
        #expect(!BindPolicy.allowRemoteFromEnvironment(["MEISTER_ALLOW_REMOTE": "true"]))
        #expect(!BindPolicy.allowRemoteFromEnvironment(["MEISTER_ALLOW_REMOTE": "0"]))
        #expect(!BindPolicy.allowRemoteFromEnvironment([:]))
    }
}
