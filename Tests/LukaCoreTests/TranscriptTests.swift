import Foundation
import Testing
@testable import LukaCore

@MainActor
private func replay(_ fixture: String) throws -> Transcript {
    let url = Bundle.module.url(forResource: fixture, withExtension: "jsonl", subdirectory: "Fixtures")!
    let transcript = Transcript()
    for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
        transcript.ingest(try SonioxResponse.decode(String(line)))
    }
    return transcript
}

@MainActor
@Suite struct TranscriptTests {
    @Test func oneWayPairsTranslationsWithTheirSentences() throws {
        let t = try replay("one_way")
        let first = try #require(t.lines.first)
        #expect(first.original == "Good morning everyone. Today we are going to review the launch plan for the new translation app.")
        #expect(first.translation.hasPrefix("여러분, 좋은 아침입니다."))
        #expect(first.translation.hasSuffix("새 번역 앱에 대한 내용입니다."))
        #expect(first.pendingOriginal.isEmpty)
        #expect(!first.isOpen)
        #expect(t.provisional == nil)

        let korean = try #require(t.lines.first { $0.language == "ko" })
        #expect(!korean.expectsTranslation)
        #expect(korean.primary == korean.original)

        let chinese = try #require(t.lines.first { $0.language == "zh" })
        #expect(chinese.original.hasPrefix("我觉得"))
        #expect(chinese.translation.contains("2주"))
        #expect(t.lines.allSatisfy { $0.pendingOriginal.isEmpty })
    }

    @Test func twoWayTranslatesBothDirections() throws {
        let t = try replay("two_way")
        let english = try #require(t.lines.first { $0.language == "en" })
        let korean = try #require(t.lines.first { $0.language == "ko" })
        #expect(english.translation.hasPrefix("여러분"))
        #expect(korean.translation.hasPrefix("Yes, that's good."))
        let chinese = try #require(t.lines.first { $0.language == "zh" })
        #expect(!chinese.expectsTranslation)
    }

    @Test func transcribeOnlyKeepsOriginals() throws {
        let t = try replay("transcribe")
        #expect(t.lines.count == 6)
        #expect(t.lines.allSatisfy { !$0.expectsTranslation && $0.primary == $0.original })
        #expect(t.lines[4].original == "How long will the beta testing take?")
    }

    @Test func provisionalTracksLiveSpeaker() throws {
        let t = Transcript()
        t.ingest(SonioxResponse(tokens: [
            .init(text: "Hel", isFinal: false, speaker: "2", language: "en", translationStatus: "original"),
            .init(text: "lo", isFinal: false, speaker: "2", language: "en", translationStatus: "original"),
        ]))
        #expect(t.provisional?.text == "Hello")
        #expect(t.currentSpeaker == SpeakerID(epoch: 0, label: "2"))
        t.ingest(SonioxResponse(tokens: [.init(text: "Hello.", isFinal: true, speaker: "2", language: "en", translationStatus: "original")]))
        #expect(t.provisional == nil)
        #expect(t.lines.last?.pendingOriginal == "Hello.")
    }

    @Test func renameAndMergeFollowCanonicalSpeaker() throws {
        let t = try replay("one_way")
        let ids = t.visibleSpeakers.map(\.id)
        #expect(ids.count >= 3)
        t.rename(ids[0], to: "Alex")
        t.merge(ids[2], into: ids[1])
        t.rename(ids[2], to: "Mina")
        #expect(t.speaker(ids[1])?.name == "Mina")
        #expect(t.speaker(ids[2])?.id == ids[1])
        #expect(!t.visibleSpeakers.contains { $0.id == ids[2] })
        let turnSpeakers = t.turns.map(\.speaker)
        #expect(!turnSpeakers.contains(ids[2]))
        for pair in zip(turnSpeakers, turnSpeakers.dropFirst()) { #expect(pair.0 != pair.1) }
    }

    @Test func newStreamSeparatesSpeakerLabels() throws {
        let t = Transcript()
        t.ingest(SonioxResponse(tokens: [.init(text: "One.", isFinal: true, speaker: "1", translationStatus: "none")]))
        t.beginStream()
        t.ingest(SonioxResponse(tokens: [.init(text: "Two.", isFinal: true, speaker: "1", translationStatus: "none")]))
        #expect(t.lines.count == 2)
        #expect(t.visibleSpeakers.map(\.ordinal) == [1, 2])
    }

    @Test func configPayloadMatchesMode() {
        var c = SessionConfig(mode: .translate, source: nil, target: "ko", languageA: "en", languageB: "ko", context: "")
        var p = c.payload(apiKey: "k")
        #expect((p["translation"] as? [String: String])?["target_language"] == "ko")
        #expect(p["language_hints"] == nil)
        #expect(p["context"] == nil)
        c.mode = .twoWay
        c.context = "Standup"
        p = c.payload(apiKey: "k", carryover: "hi")
        #expect((p["translation"] as? [String: String])?["type"] == "two_way")
        #expect((p["context"] as? [String: String])?["text"] == "Standup\n\nRecent conversation: hi")
        c.mode = .transcribe
        #expect(c.payload(apiKey: "k")["translation"] == nil)
    }

    @Test func snapshotRoundTripKeepsSpeakersAndEdits() throws {
        let t = try replay("one_way")
        t.title = "Standup"
        let first = try #require(t.visibleSpeakers.first)
        t.rename(first.id, to: "Alex")
        t.edit(line: t.lines[0].id, translation: "고친 번역")
        t.delete(line: t.lines[1].id)
        let data = try JSONEncoder().encode(t.snapshot)
        let back = Transcript(snapshot: try JSONDecoder().decode(TranscriptSnapshot.self, from: data))
        #expect(back.id == t.id)
        #expect(back.title == "Standup")
        #expect(back.lines == t.lines.map { var l = $0; l.isOpen = false; return l })
        #expect(back.speaker(first.id)?.name == "Alex")
        #expect(back.lines[0].translation == "고친 번역")
        back.beginStream()
        back.ingest(SonioxResponse(tokens: [.init(text: "More.", isFinal: true, speaker: "1", translationStatus: "none")]))
        #expect(back.lines.last?.id == t.nextLineID)
        #expect(back.visibleSpeakers.last?.ordinal == t.visibleSpeakers.count + 1)
    }

    @Test func plainTextListsTurns() throws {
        let t = try replay("transcribe")
        let text = t.plainText(name: { "S\($0.label)" }, includeOriginal: false)
        #expect(text.contains("] S1\nGood morning everyone."))
        #expect(text.components(separatedBy: "\n\n").count == t.turns.count)
    }
}
