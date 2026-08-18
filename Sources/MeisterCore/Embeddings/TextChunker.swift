import Foundation

public enum TextChunker: Sendable {
    public static func chunks(
        _ text: String,
        targetTokens: Int = 1000,
        overlapTokens: Int = 100
    ) -> [String] {
        let targetChars = max(targetTokens, 1) * 4
        let overlapChars = max(overlapTokens, 0) * 4
        if text.isEmpty { return [] }
        if text.utf8.count <= targetChars { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = start
            var count = 0
            while end < text.endIndex, count < targetChars {
                count += text[end].utf8.count
                end = text.index(after: end)
            }
            result.append(String(text[start..<end]))
            if end >= text.endIndex { break }
            var back = 0
            var cursor = end
            while cursor > start, back < overlapChars {
                cursor = text.index(before: cursor)
                back += text[cursor].utf8.count
            }
            start = cursor
        }
        return result
    }
}
