import Foundation

public enum EmbeddingVector: Sendable {
    public static func encode(_ values: [Float]) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(values.count * 4)
        for value in values {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        return Data(bytes)
    }

    public static func decode(_ data: Data) -> [Float] {
        guard data.count >= 4, data.count % 4 == 0 else { return [] }
        var values: [Float] = []
        values.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + 4 <= bytes.count {
                let bits = UInt32(bytes[offset])
                    | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16)
                    | (UInt32(bytes[offset + 3]) << 24)
                values.append(Float(bitPattern: bits))
                offset += 4
            }
        }
        return values
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for index in 0..<n {
            let x = a[index]
            let y = b[index]
            dot += x * y
            na += x * x
            nb += y * y
        }
        let denom = (na.squareRoot() * nb.squareRoot())
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    /// Deterministic bag-of-tokens vector for tests and offline retrieve.
    public static func hashEmbedding(_ text: String, dimensions: Int = 32) -> [Float] {
        let dim = max(dimensions, 8)
        var values = [Float](repeating: 0, count: dim)
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }
        for token in tokens {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            let index = Int(hash % UInt64(dim))
            let sign: Float = (hash & 1) == 0 ? 1 : -1
            values[index] += sign
        }
        let norm = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 {
            for index in values.indices {
                values[index] /= norm
            }
        }
        return values
    }
}
