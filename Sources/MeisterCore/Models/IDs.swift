import Foundation

public struct JobID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> JobID {
        JobID(UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }
}

public struct FindingID: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate(at date: Date = Date()) -> FindingID {
        FindingID("fnd_" + CrockfordULID.generate(at: date))
    }
}

public struct RuleID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public var isValid: Bool {
        rawValue.wholeMatch(of: /^[a-z0-9][a-z0-9-]{1,126}$/) != nil
    }

    public static func slug(from title: String) -> RuleID {
        var scalars: [Character] = []
        for character in title.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                scalars.append(character)
            } else if scalars.last != "-" {
                scalars.append("-")
            }
        }
        var slug = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty {
            slug = "rule"
        }
        if slug.count == 1 {
            slug = "r-\(slug)"
        }
        if slug.count > 127 {
            slug = String(slug.prefix(127)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        if slug.count < 2 {
            slug = "rule"
        }
        return RuleID(slug)
    }
}

enum CrockfordULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate(at date: Date) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var millis = UInt64(date.timeIntervalSince1970 * 1000)
        for index in (0..<6).reversed() {
            bytes[index] = UInt8(truncatingIfNeeded: millis)
            millis >>= 8
        }
        var generator = SystemRandomNumberGenerator()
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return encode(bytes)
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        var bits: UInt64 = 0
        var bitCount = 0
        var chars: [Character] = []
        chars.reserveCapacity(26)
        for byte in bytes {
            bits = (bits << 8) | UInt64(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((bits >> bitCount) & 0x1F)
                chars.append(alphabet[index])
            }
        }
        if bitCount > 0 {
            let index = Int((bits << (5 - bitCount)) & 0x1F)
            chars.append(alphabet[index])
        }
        return String(chars.prefix(26))
    }
}
