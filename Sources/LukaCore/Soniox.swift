import Foundation

public struct SonioxToken: Decodable, Sendable, Equatable {
    public var text: String
    public var startMs: Int?
    public var endMs: Int?
    public var isFinal: Bool
    public var speaker: String?
    public var language: String?
    public var translationStatus: String?

    public init(text: String, isFinal: Bool, speaker: String? = nil, language: String? = nil, translationStatus: String? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.speaker = speaker
        self.language = language
        self.translationStatus = translationStatus
    }

    enum CodingKeys: String, CodingKey {
        case text, speaker, language
        case startMs = "start_ms"
        case endMs = "end_ms"
        case isFinal = "is_final"
        case translationStatus = "translation_status"
    }

    public var isTranslation: Bool { translationStatus == "translation" }
    public var isMarker: Bool { text == "<end>" || text == "<fin>" }
}

public struct SonioxResponse: Decodable, Sendable {
    public var tokens: [SonioxToken]
    public var finished: Bool
    public var errorCode: Int?
    public var errorMessage: String?

    public init(tokens: [SonioxToken], finished: Bool = false) {
        self.tokens = tokens
        self.finished = finished
    }

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decodeIfPresent([SonioxToken].self, forKey: .tokens) ?? []
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        errorCode = try c.decodeIfPresent(Int.self, forKey: .errorCode)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    public static func decode(_ text: String) throws -> SonioxResponse {
        try JSONDecoder().decode(SonioxResponse.self, from: Data(text.utf8))
    }
}

public enum TranslationMode: String, Codable, CaseIterable, Sendable {
    case translate, twoWay, transcribe
}

public struct SessionConfig: Sendable, Equatable {
    public var mode: TranslationMode
    /// Soniox language code, or `nil` for automatic detection.
    public var source: String?
    public var target: String
    public var languageA: String
    public var languageB: String
    public var context: String

    public init(mode: TranslationMode, source: String?, target: String, languageA: String, languageB: String, context: String) {
        self.mode = mode
        self.source = source
        self.target = target
        self.languageA = languageA
        self.languageB = languageB
        self.context = context
    }

    public static let model = "stt-rt-v5"

    public func payload(apiKey: String, carryover: String? = nil) -> [String: Any] {
        var cfg: [String: Any] = [
            "api_key": apiKey,
            "model": Self.model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
            "enable_speaker_diarization": true,
            "enable_language_identification": true,
        ]
        switch mode {
        case .translate:
            cfg["translation"] = ["type": "one_way", "target_language": target]
            if let source { cfg["language_hints"] = [source] }
        case .twoWay:
            cfg["translation"] = ["type": "two_way", "language_a": languageA, "language_b": languageB]
            cfg["language_hints"] = [languageA, languageB]
        case .transcribe:
            if let source { cfg["language_hints"] = [source] }
        }
        let text = [context.trimmingCharacters(in: .whitespacesAndNewlines), carryover.map { "Recent conversation: \($0)" } ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !text.isEmpty { cfg["context"] = ["text": text] }
        return cfg
    }

    public func json(apiKey: String, carryover: String? = nil) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload(apiKey: apiKey, carryover: carryover), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
