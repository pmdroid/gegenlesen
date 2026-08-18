import Foundation

public enum ContextPack: Sendable {
    public static func markdown(
        notes: [ContextNote],
        hits: [ContextRetrieveHit]
    ) -> String {
        var sections: [String] = ["# Project context", ""]
        let architecture = notes.filter { $0.kind == .architecture && $0.deletedAt == nil }
        let user = notes.filter { $0.kind == .user && $0.deletedAt == nil }
        if !architecture.isEmpty {
            sections.append("## Architecture")
            for note in architecture {
                sections.append("### \(note.title)")
                sections.append(note.body)
                sections.append("")
            }
        }
        if !user.isEmpty {
            sections.append("## Operator notes")
            for note in user {
                sections.append("### \(note.title)")
                sections.append(note.body)
                sections.append("")
            }
        }
        let noteIDs = Set(notes.map(\.id))
        let extra = hits.filter { !noteIDs.contains($0.chunk.ref) }
        if !extra.isEmpty {
            sections.append("## Retrieved chunks")
            for hit in extra {
                sections.append("### \(hit.chunk.kind.rawValue) · \(hit.chunk.ref)")
                sections.append(hit.chunk.text)
                sections.append("")
            }
        }
        return sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    public static func write(
        workspace: Workspace,
        notes: [ContextNote],
        hits: [ContextRetrieveHit]
    ) throws {
        let meister = workspace.root.appendingPathComponent(".meister", isDirectory: true)
        try FileManager.default.createDirectory(at: meister, withIntermediateDirectories: true)
        let text = markdown(notes: notes, hits: hits)
        try text.write(
            to: meister.appendingPathComponent("context.md"),
            atomically: true,
            encoding: .utf8
        )
    }
}
