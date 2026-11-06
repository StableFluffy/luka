import Foundation
import Observation

/// Soniox speaker labels restart at "1" on every stream, so a label is only unique within its epoch.
public struct SpeakerID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var epoch: Int
    public var label: String
    public init(epoch: Int, label: String) {
        self.epoch = epoch
        self.label = label
    }
    public var description: String { "\(epoch):\(label)" }
}

public struct Speaker: Identifiable, Sendable, Equatable, Codable {
    public let id: SpeakerID
    public let ordinal: Int
    public var name: String
    public var colorIndex: Int
    public var mergedInto: SpeakerID?
}

public struct Line: Identifiable, Sendable, Equatable, Codable {
    public let id: Int
    public var speaker: SpeakerID?
    public var language: String?
    public var original: String = ""
    public var translation: String = ""
    /// Finalized source text whose translation hasn't arrived yet.
    public var pendingOriginal: String = ""
    public var expectsTranslation = false
    public var startedAt: Date
    public var isOpen = true
    /// The language `translation` is in.
    public var translationLanguage: String?
    /// Three-way mode's other translations, by language.
    public var extraTranslations: [String: String]?
    /// Where the line sits in the audio sent this run, in ms. Not saved: it only lines up streams while listening.
    public var startMs: Int?
    public var endMs: Int?

    enum CodingKeys: String, CodingKey {
        case id, speaker, language, original, translation, pendingOriginal, expectsTranslation, startedAt, isOpen
        case translationLanguage, extraTranslations
    }

    /// Every translation of the line, in a stable language order.
    public var translations: [(language: String?, text: String)] {
        var all: [(language: String?, text: String)] = translation.isEmpty ? [] : [(translationLanguage, translation)]
        for (language, text) in extraTranslations ?? [:] where !text.isEmpty && language != translationLanguage {
            all.append((language, text))
        }
        return all.sorted { Languages.rank($0.language) < Languages.rank($1.language) }
    }

    /// The translation into `language`, if one has arrived.
    public func translation(in language: String) -> String? {
        translations.first { $0.language == language }?.text
    }

    /// All translations, one per line.
    public var translatedText: String { translations.map(\.text).joined(separator: "\n") }

    /// The text a reader cares about: the translation when one is coming, otherwise what was said.
    public var primary: String { expectsTranslation ? translatedText : original }
    public var untranslatedTail: String { expectsTranslation ? pendingOriginal : "" }
}

public struct Provisional: Sendable, Equatable {
    public var speaker: SpeakerID?
    public var language: String?
    public var text: String
    public var translation: String
}

public struct Turn: Identifiable, Sendable, Equatable {
    public var id: Int { lines.first?.id ?? -1 }
    public var speaker: SpeakerID?
    public var lines: [Line]
    public init(speaker: SpeakerID?, lines: [Line]) {
        self.speaker = speaker
        self.lines = lines
    }
}

/// Everything needed to save a session and reopen it later.
public struct TranscriptSnapshot: Codable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lines: [Line]
    public var speakers: [Speaker]
    public var speakerOrder: [SpeakerID]
    public var epoch: Int
    public var nextLineID: Int
    public var nextOrdinal: Int
    public var nextColor: Int
}

@MainActor
@Observable
public final class Transcript: Identifiable {
    public let id: UUID
    /// When listening first started; until then, when the session was opened.
    public private(set) var createdAt: Date
    /// Whether listening has started in this session. Saved sessions always have lines, so this is only for new ones.
    public var hasStarted: Bool { !lines.isEmpty || startedListening }
    private var startedListening = false
    public var title: String { didSet { if title != oldValue { touch() } } }
    public private(set) var updatedAt: Date
    /// Bumped on every content change; used to decide when to save.
    @ObservationIgnored public private(set) var revision = 0

    public private(set) var lines: [Line] = []
    public private(set) var speakers: [SpeakerID: Speaker] = [:]
    public private(set) var speakerOrder: [SpeakerID] = []
    public private(set) var provisional: Provisional?
    public private(set) var epoch = 0

    @ObservationIgnored private var openLine: Int?
    @ObservationIgnored public private(set) var nextLineID = 0
    @ObservationIgnored private var nextOrdinal = 1
    @ObservationIgnored private var nextColor = 0
    /// The end of the latest finalized source word, on the audio clock.
    @ObservationIgnored private var finalizedMs = 0
    /// Three-way translation streams, by lane.
    @ObservationIgnored private var lanes: [Int: Lane] = [:]

    /// A run of translated text from an extra stream, and the stretch of audio it translates.
    private struct Segment {
        var language: String
        var start: Int?
        var end: Int?
        /// The line it was attached to; until then, `text` holds what arrived.
        var line: Int?
        var text = ""
    }

    private struct Lane {
        var spokenStart: Int?
        var spokenEnd: Int?
        var translating = false
        var segments: [Segment] = []
    }

    public static let paletteSize = 8
    static let softLineLimit = 280

    public init(id: UUID = UUID(), title: String = "", createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public init(snapshot s: TranscriptSnapshot) {
        id = s.id
        title = s.title
        createdAt = s.createdAt
        updatedAt = s.updatedAt
        lines = s.lines.map { var l = $0; l.isOpen = false; return l }
        speakers = Dictionary(uniqueKeysWithValues: s.speakers.map { ($0.id, $0) })
        speakerOrder = s.speakerOrder
        epoch = s.epoch
        nextLineID = s.nextLineID
        nextOrdinal = s.nextOrdinal
        nextColor = s.nextColor
    }

    public var snapshot: TranscriptSnapshot {
        TranscriptSnapshot(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, lines: lines,
                           speakers: speakerOrder.compactMap { speakers[$0] }, speakerOrder: speakerOrder,
                           epoch: epoch, nextLineID: nextLineID, nextOrdinal: nextOrdinal, nextColor: nextColor)
    }

    /// Stamps the session with the time listening first starts.
    public func markStarted(at date: Date = .now) {
        guard !hasStarted else { return }
        startedListening = true
        createdAt = date
    }

    private func touch() {
        revision += 1
        updatedAt = .now
    }

    public var isEmpty: Bool { lines.isEmpty && provisional == nil }

    // MARK: Ingest

    /// `baseMs` is where this stream's audio starts on the audio clock, so its token times line up with other streams.
    public func ingest(_ response: SonioxResponse, at now: Date = .now, baseMs: Int = 0) {
        var provisionalText = ""
        var provisionalTranslation = ""
        var provisionalSpeaker: SpeakerID?
        var provisionalLanguage: String?
        var translated = Set<Int>()
        if response.tokens.contains(where: { $0.isFinal && !$0.isMarker }) { touch() }

        for token in response.tokens {
            if token.isMarker {
                if token.isFinal { closeOpenLine() }
                continue
            }
            let speaker = token.speaker.map { register(label: $0) }
            if token.isFinal {
                if token.isTranslation {
                    if let i = appendTranslation(token, speaker: speaker) { translated.insert(i) }
                } else {
                    appendOriginal(token, speaker: speaker, at: now, baseMs: baseMs)
                }
            } else if token.isTranslation {
                provisionalTranslation += token.text
            } else {
                if provisionalText.isEmpty {
                    provisionalSpeaker = speaker
                    provisionalLanguage = token.language
                }
                provisionalText += token.text
            }
        }
        for i in translated { lines[i].pendingOriginal = "" }

        let trimmed = provisionalText.trimmingCharacters(in: .whitespaces)
        let next = trimmed.isEmpty && provisionalTranslation.isEmpty
            ? nil
            : Provisional(speaker: provisionalSpeaker, language: provisionalLanguage,
                          text: trimmed, translation: provisionalTranslation)
        if next != provisional { provisional = next }
        if !lanes.isEmpty { resolveSegments(force: false) }
    }

    /// A three-way stream that hears the same audio but translates into another language.
    /// Only its translations are kept; each run of them goes to the line whose audio it overlaps most.
    public func ingestTranslation(_ response: SonioxResponse, lane id: Int, baseMs: Int) {
        var lane = lanes[id] ?? Lane()
        for token in response.tokens where token.isFinal && !token.isMarker {
            if token.isTranslation {
                if !lane.translating || lane.segments.isEmpty {
                    lane.segments.append(Segment(language: token.language ?? "", start: lane.spokenStart, end: lane.spokenEnd))
                    lane.spokenStart = nil
                    lane.spokenEnd = nil
                    lane.translating = true
                }
                let k = lane.segments.count - 1
                if let lineID = lane.segments[k].line, let i = lines.firstIndex(where: { $0.id == lineID }) {
                    appendExtra(token.text, language: lane.segments[k].language, at: i, continuing: true)
                } else {
                    lane.segments[k].text += token.text
                }
            } else if token.translationStatus == "original" {
                lane.translating = false
                if let start = token.startMs, lane.spokenStart == nil { lane.spokenStart = baseMs + start }
                if let end = token.endMs { lane.spokenEnd = baseMs + end }
            }
        }
        lanes[id] = lane
        resolveSegments(force: false)
    }

    /// Attaches waiting translations once the transcript has caught up with their audio; `force` attaches them all now.
    private func resolveSegments(force: Bool) {
        for id in lanes.keys {
            guard var lane = lanes[id] else { continue }
            for k in lane.segments.indices where lane.segments[k].line == nil {
                let segment = lane.segments[k]
                if !force, let end = segment.end, finalizedMs < end - 250 { break }
                guard let i = lineIndex(start: segment.start, end: segment.end) else { break }
                lane.segments[k].line = lines[i].id
                lane.segments[k].text = ""
                appendExtra(segment.text, language: segment.language, at: i, continuing: false)
            }
            let last = lane.segments.count - 1
            lane.segments = lane.segments.enumerated().filter { $0.element.line == nil || $0.offset == last }.map(\.element)
            lanes[id] = lane
        }
    }

    /// The recent line that overlaps this stretch of audio the most, or the nearest one.
    private func lineIndex(start: Int?, end: Int?) -> Int? {
        let timed = lines.indices.suffix(12).filter { lines[$0].startMs != nil }
        guard let start, !timed.isEmpty else { return timed.last ?? lines.indices.last }
        let end = max(end ?? start, start)
        func score(_ i: Int) -> Int {
            let s = lines[i].startMs!
            let e = max(lines[i].endMs ?? s, s)
            let overlap = min(end, e) - max(start, s)
            return overlap > 0 ? overlap : overlap - 1_000_000
        }
        return timed.max { score($0) < score($1) }
    }

    private func appendExtra(_ text: String, language: String, at i: Int, continuing: Bool) {
        guard !text.isEmpty else { return }
        var extras = lines[i].extraTranslations ?? [:]
        let current = extras[language] ?? ""
        if current.isEmpty {
            extras[language] = String(text.drop(while: \.isWhitespace))
        } else if continuing || text.first?.isWhitespace == true || ["zh", "ja"].contains(language) {
            extras[language] = current + text
        } else {
            extras[language] = current + " " + text
        }
        lines[i].extraTranslations = extras
        lines[i].expectsTranslation = true
        touch()
    }

    /// Call when a new Soniox stream starts; its speaker labels mean new people.
    public func beginStream() {
        closeOpenLine()
        provisional = nil
        epoch += 1
    }

    /// Call when streams stop: drops the live text and attaches any translations still waiting.
    public func clearProvisional() {
        provisional = nil
        resolveSegments(force: true)
        lanes = [:]
    }

    public func reset() {
        lines = []
        speakers = [:]
        speakerOrder = []
        provisional = nil
        openLine = nil
        nextOrdinal = 1
        nextColor = 0
        lanes = [:]
        epoch += 1
    }

    private func appendOriginal(_ token: SonioxToken, speaker: SpeakerID?, at now: Date, baseMs: Int) {
        if let i = openLine, speaker == nil || lines[i].speaker == nil || canonical(lines[i].speaker!) == canonical(speaker!) {
            if lines[i].speaker == nil { lines[i].speaker = speaker }
        } else {
            closeOpenLine()
            lines.append(Line(id: nextLineID, speaker: speaker, language: token.language, startedAt: now))
            nextLineID += 1
            openLine = lines.count - 1
        }
        let i = openLine!
        let text = lines[i].original.isEmpty ? String(token.text.drop(while: \.isWhitespace)) : token.text
        lines[i].original += text
        if token.translationStatus == "original" {
            lines[i].expectsTranslation = true
            lines[i].pendingOriginal += lines[i].pendingOriginal.isEmpty ? String(text.drop(while: \.isWhitespace)) : text
        }
        if lines[i].language == nil { lines[i].language = token.language }
        if let start = token.startMs, lines[i].startMs == nil { lines[i].startMs = baseMs + start }
        if let end = token.endMs {
            lines[i].endMs = baseMs + end
            finalizedMs = max(finalizedMs, baseMs + end)
        }

        if lines[i].original.count > Self.softLineLimit, let last = text.last, ".?!。？！".contains(last) {
            closeOpenLine()
        }
    }

    private func appendTranslation(_ token: SonioxToken, speaker: SpeakerID?) -> Int? {
        let text = token.text
        let lower = max(0, lines.count - 8)
        let candidates = lines.indices.reversed().filter { $0 >= lower }
        let sameSpeaker: (Int) -> Bool = { i in
            guard let speaker, let s = self.lines[i].speaker else { return true }
            return self.canonical(s) == self.canonical(speaker)
        }
        guard let i = candidates.first(where: { !lines[$0].pendingOriginal.isEmpty && sameSpeaker($0) })
            ?? candidates.first(where: { lines[$0].expectsTranslation && sameSpeaker($0) })
            ?? lines.indices.last
        else { return nil }
        lines[i].expectsTranslation = true
        if lines[i].translationLanguage == nil { lines[i].translationLanguage = token.language }
        lines[i].translation += lines[i].translation.isEmpty ? String(text.drop(while: \.isWhitespace)) : text
        return i
    }

    private func closeOpenLine() {
        if let i = openLine { lines[i].isOpen = false }
        openLine = nil
    }

    private func register(label: String) -> SpeakerID {
        let id = SpeakerID(epoch: epoch, label: label)
        if speakers[id] == nil {
            speakers[id] = Speaker(id: id, ordinal: nextOrdinal, name: "", colorIndex: nextColor % Self.paletteSize)
            speakerOrder.append(id)
            nextOrdinal += 1
            nextColor += 1
        }
        return id
    }

    // MARK: Speakers

    public func canonical(_ id: SpeakerID) -> SpeakerID {
        var current = id
        var hops = 0
        while let next = speakers[current]?.mergedInto, hops < 32 {
            current = next
            hops += 1
        }
        return current
    }

    public func speaker(_ id: SpeakerID?) -> Speaker? {
        guard let id else { return nil }
        return speakers[canonical(id)]
    }

    /// Speakers the user can see: merged-away speakers are hidden.
    public var visibleSpeakers: [Speaker] {
        speakerOrder.compactMap { speakers[$0] }.filter { $0.mergedInto == nil }
    }

    /// Who is talking right now, or who talked last.
    public var currentSpeaker: SpeakerID? {
        if let s = provisional?.speaker { return canonical(s) }
        return lines.last(where: { $0.speaker != nil })?.speaker.map(canonical)
    }

    public func rename(_ id: SpeakerID, to name: String) {
        let target = canonical(id)
        speakers[target]?.name = name
        touch()
    }

    public func recolor(_ id: SpeakerID, to index: Int) {
        speakers[canonical(id)]?.colorIndex = index % Self.paletteSize
        touch()
    }

    // MARK: Editing

    /// `language` picks which translation `translation` replaces; nil or the main one's language edits the main one.
    public func edit(line id: Int, original: String? = nil, translation: String? = nil, language: String? = nil) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        if let original { lines[i].original = original }
        if let translation {
            if let language, language != lines[i].translationLanguage, lines[i].extraTranslations?[language] != nil {
                lines[i].extraTranslations?[language] = translation
            } else {
                lines[i].translation = translation
            }
        }
        touch()
    }

    public func delete(line id: Int) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        if openLine == i { openLine = nil } else if let o = openLine, o > i { openLine = o - 1 }
        lines.remove(at: i)
        touch()
    }

    public func merge(_ source: SpeakerID, into destination: SpeakerID) {
        let from = canonical(source)
        let to = canonical(destination)
        guard from != to else { return }
        if speakers[to]?.name.isEmpty == true, let name = speakers[from]?.name, !name.isEmpty {
            speakers[to]?.name = name
        }
        speakers[from]?.mergedInto = to
        touch()
    }

    // MARK: Views

    public var turns: [Turn] {
        var result: [Turn] = []
        for line in lines {
            let s = line.speaker.map(canonical)
            if let last = result.indices.last, result[last].speaker == s {
                result[last].lines.append(line)
            } else {
                result.append(Turn(speaker: s, lines: [line]))
            }
        }
        return result
    }

    /// Recent source text, used to prime a replacement stream after a reconnect.
    public func recentContext(maxCharacters: Int = 600) -> String? {
        var parts: [String] = []
        var total = 0
        for line in lines.reversed() {
            let text = line.original
            if total + text.count > maxCharacters { break }
            parts.insert(text, at: 0)
            total += text.count
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}
