import Foundation
import LukaCore

/// Sessions live as one JSON file each in Application Support/Luka/Sessions.
@MainActor
@Observable
final class SessionStore {
    struct Summary: Identifiable, Equatable {
        let id: UUID
        var title: String
        let createdAt: Date
        var updatedAt: Date
        var preview: String
    }

    private(set) var summaries: [Summary] = []
    @ObservationIgnored private var cache: [UUID: Transcript] = [:]
    @ObservationIgnored private var savedRevision: [UUID: Int] = [:]
    @ObservationIgnored private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--sessions-dir"), args.indices.contains(i + 1) {
            directory = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        } else {
            directory = base.appendingPathComponent("Luka/Sessions", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? decoder.decode(TranscriptSnapshot.self, from: data) else { continue }
            summaries.append(Self.summary(of: snapshot))
        }
        summaries.sort { $0.createdAt > $1.createdAt }
    }

    func transcript(_ id: UUID) -> Transcript? {
        if let cached = cache[id] { return cached }
        guard let data = try? Data(contentsOf: url(id)),
              let snapshot = try? JSONDecoder().decode(TranscriptSnapshot.self, from: data) else { return nil }
        let transcript = Transcript(snapshot: snapshot)
        cache[id] = transcript
        savedRevision[id] = transcript.revision
        return transcript
    }

    func track(_ transcript: Transcript) {
        cache[transcript.id] = transcript
    }

    /// Writes the session if it changed. Sessions with nothing said are never written.
    func save(_ transcript: Transcript) {
        cache[transcript.id] = transcript
        guard !transcript.lines.isEmpty, savedRevision[transcript.id] != transcript.revision else { return }
        let snapshot = transcript.snapshot
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url(transcript.id), options: .atomic)
        savedRevision[transcript.id] = transcript.revision
        let summary = Self.summary(of: snapshot)
        if let i = summaries.firstIndex(where: { $0.id == transcript.id }) {
            summaries[i] = summary
        } else {
            summaries.insert(summary, at: 0)
            summaries.sort { $0.createdAt > $1.createdAt }
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
        cache[id] = nil
        savedRevision[id] = nil
        summaries.removeAll { $0.id == id }
    }

    private func url(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func summary(of s: TranscriptSnapshot) -> Summary {
        let first = s.lines.first.map { $0.expectsTranslation && !$0.translation.isEmpty ? $0.translation : $0.original } ?? ""
        return Summary(id: s.id, title: s.title, createdAt: s.createdAt, updatedAt: s.updatedAt, preview: String(first.prefix(120)))
    }
}
