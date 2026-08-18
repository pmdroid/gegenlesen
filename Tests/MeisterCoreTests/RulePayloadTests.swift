import Foundation
import Testing
@testable import MeisterCore

@Suite
struct RulePayloadTests {
    @Test
    func instructionMakesSemantic() throws {
        let data = Data(#"{"instruction":"Flag N+1 queries.","few_shots":["a"]}"#.utf8)
        let payload = try JSONDecoder().decode(RulePayload.self, from: data)
        #expect(payload == .semantic(instruction: "Flag N+1 queries.", fewShots: ["a"]))
    }

    @Test
    func checkerSwitchAndTimeoutCap() throws {
        let data = Data(#"{"checker":"command","argv":["python3"],"timeout_sec":99}"#.utf8)
        let payload = try JSONDecoder().decode(RulePayload.self, from: data)
        #expect(payload == .command(argv: ["python3"], timeoutSec: 20))

        let encoded = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONEncoder().encode(payload)
        )
        #expect(encoded["timeout_sec"] == .int(20))
        #expect(encoded["checker"] == .string("command"))
    }

    @Test
    func regexRoundTrip() throws {
        let payload = RulePayload.regex(pattern: "foo", flags: "i", message: "no")
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(RulePayload.self, from: data)
        #expect(decoded == payload)
    }
}

private enum JSONValue: Decodable, Equatable {
    case string(String)
    case int(Int)
    case array([JSONValue])
    case object([String: JSONValue])
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }
}