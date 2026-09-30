import Foundation

public enum Languages {
    /// Soniox real-time languages (stt-rt-v5), ISO 639-1.
    public static let all: [String] = [
        "af", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es", "et",
        "eu", "fa", "fi", "fr", "gl", "gu", "he", "hi", "hr", "hu", "id", "it", "ja", "kk", "kn", "ko",
        "lt", "lv", "mk", "ml", "mr", "ms", "nl", "no", "pa", "pl", "pt", "ro", "ru", "sk", "sl", "sq",
        "sr", "sv", "sw", "ta", "te", "th", "tl", "tr", "uk", "ur", "vi", "zh",
    ]

    public static let pinned = ["en", "ko", "zh", "ja"]

    public static func name(_ code: String, in locale: Locale) -> String {
        locale.localizedString(forLanguageCode: code).map { $0.capitalized(with: locale) } ?? code.uppercased()
    }

    /// Pinned languages first, the rest alphabetically in the display locale.
    public static func ordered(in locale: Locale) -> [String] {
        let rest = all.filter { !pinned.contains($0) }
            .sorted { name($0, in: locale).compare(name($1, in: locale), locale: locale) == .orderedAscending }
        return pinned + rest
    }
}
