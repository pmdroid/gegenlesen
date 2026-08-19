import CryptoKit
import Foundation

public enum ContentHash: Sendable {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return sha256(data)
    }
}
