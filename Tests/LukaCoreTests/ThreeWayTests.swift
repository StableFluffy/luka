import Foundation
import Testing
@testable import LukaCore

private func token(_ text: String, _ start: Int? = nil, _ end: Int? = nil, speaker: String? = nil,
                   language: String, status: String) -> SonioxToken {
    var t = SonioxToken(text: text, isFinal: true, speaker: speaker, language: language, translationStatus: status)
    t.startMs = start
    t.endMs = end
    return t
}

/// Lane 0 translates into Korean and carries the transcript.
private let primary = [
    SonioxResponse(tokens: [token("你好", 0, 1_800, speaker: "1", language: "zh", status: "original")]),
    SonioxResponse(tokens: [token("안녕하세요", language: "ko", status: "translation"),
                            token("<end>", language: "zh", status: "none")]),
    SonioxResponse(tokens: [token("반갑습니다", 2_500, 4_000, speaker: "2", language: "ko", status: "none"),
                            token("<end>", language: "ko", status: "none")]),
]

/// Lane 1 translates into English. Its speech runs the same two sentences.
private func english(offset: Int) -> [SonioxResponse] {
    [
        SonioxResponse(tokens: [token("你好", 0 - offset + 20, 1_790 - offset, language: "zh", status: "original")]),
        SonioxResponse(tokens: [token("Hello", language: "en", status: "translation")]),
        SonioxResponse(tokens: [token("반갑습니다", 2_510 - offset, 3_990 - offset, language: "ko", status: "original"),
                                token("Nice to", language: "en", status: "translation"),
                                token(" meet you", language: "en", status: "translation")]),
    ]
}

@MainActor
@Suite struct ThreeWayTests {
    @Test func configRunsOneStreamPerLanguage() {
        let config = SessionConfig(mode: .threeWay, source: nil, target: "en", languageA: "zh", languageB: "ko",
                                   languageC: "en", context: "")
        #expect(config.lanes == 3)
        let targets = (0..<3).map { (config.payload(apiKey: "k", lane: $0)["translation"] as? [String: String])?["target_language"] }
        #expect(targets == ["zh", "ko", "en"])
        #expect(config.payload(apiKey: "k", lane: 1)["enable_speaker_diarization"] as? Bool == false)

        var repeated = config
        repeated.languageC = "zh"
        #expect(repeated.lanes == 2)
    }

    @Test func extraTranslationsJoinTheLinesTheyTranslate() {
        let t = Transcript()
        primary.forEach { t.ingest($0) }
        english(offset: 0).forEach { t.ingestTranslation($0, lane: 1, baseMs: 0) }

        #expect(t.lines.count == 2)
        let chinese = t.lines[0]
        #expect(chinese.translations.map(\.language) == ["en", "ko"])
        #expect(chinese.primary == "Hello\n안녕하세요")
        let korean = t.lines[1]
        #expect(korean.expectsTranslation)
        #expect(korean.primary == "Nice to meet you")
        #expect(korean.original == "반갑습니다")
    }

    @Test func translationsThatArriveEarlyWaitForTheirLine() {
        let t = Transcript()
        // The English stream opened 300 ms of audio later, and runs ahead of the transcript.
        english(offset: 300).forEach { t.ingestTranslation($0, lane: 1, baseMs: 300) }
        #expect(t.lines.isEmpty)
        t.ingest(primary[0])
        t.ingest(primary[1])
        #expect(t.lines[0].extraTranslations?["en"] == "Hello")
        t.ingest(primary[2])
        #expect(t.lines[1].extraTranslations?["en"] == "Nice to meet you")
        #expect(t.lines[0].extraTranslations?["en"] == "Hello")
    }

    @Test func stoppingAttachesWhatIsStillWaiting() {
        let t = Transcript()
        t.ingest(primary[0])
        english(offset: 0).forEach { t.ingestTranslation($0, lane: 1, baseMs: 0) }
        #expect(t.lines[0].extraTranslations?["en"] == "Hello")
        t.clearProvisional()
        #expect(t.lines[0].extraTranslations?["en"] == "Hello Nice to meet you")
    }

    @Test func savedLinesKeepTranslationsButNotAudioTimes() throws {
        let t = Transcript()
        primary.forEach { t.ingest($0) }
        english(offset: 0).forEach { t.ingestTranslation($0, lane: 1, baseMs: 0) }
        let data = try JSONEncoder().encode(t.snapshot)
        let restored = Transcript(snapshot: try JSONDecoder().decode(TranscriptSnapshot.self, from: data))
        #expect(restored.lines[0].primary == "Hello\n안녕하세요")
        #expect(restored.lines[0].startMs == nil)

        t.edit(line: t.lines[0].id, translation: "Hi", language: "en")
        #expect(t.lines[0].primary == "Hi\n안녕하세요")
        t.edit(line: t.lines[0].id, translation: "안녕", language: "ko")
        #expect(t.lines[0].primary == "Hi\n안녕")
    }

    @Test func linesSavedBeforeThreeWayStillLoad() throws {
        let json = #"{"id":1,"original":"hi","translation":"안녕","pendingOriginal":"","expectsTranslation":true,"startedAt":0,"isOpen":false}"#
        let line = try JSONDecoder().decode(Line.self, from: Data(json.utf8))
        #expect(line.primary == "안녕")
        #expect(line.extraTranslations == nil)
    }
}
