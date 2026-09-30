import Foundation
import Observation
import SwiftUI

enum UILanguage: String, CaseIterable, Sendable {
    case system, en, ko, zh
}

/// Runtime-switchable UI language. Keys are the English strings.
@MainActor
@Observable
final class Localizer {
    static let shared = Localizer()

    var language: UILanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "uiLanguage")
            Self.active = resolved
            // Lets AppKit's own menu items (Edit, Window…) follow on the next launch.
            if language == .system {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([resolved == .zh ? "zh-Hans" : resolved.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    nonisolated(unsafe) fileprivate static var active: UILanguage = .en

    private init() {
        language = UILanguage(rawValue: UserDefaults.standard.string(forKey: "uiLanguage") ?? "") ?? .system
        Self.active = resolved
    }

    var resolved: UILanguage {
        if language != .system { return language }
        for id in Locale.preferredLanguages {
            let code = Locale(identifier: id).language.languageCode?.identifier
            if code == "ko" { return .ko }
            if code == "zh" { return .zh }
            if code == "en" { return .en }
        }
        return .en
    }

    var locale: Locale {
        switch resolved {
        case .ko: Locale(identifier: "ko")
        case .zh: Locale(identifier: "zh-Hans")
        default: Locale(identifier: "en")
        }
    }

    static func displayName(_ language: UILanguage) -> String {
        switch language {
        case .system: tr("System")
        case .en: "English"
        case .ko: "한국어"
        case .zh: "简体中文"
        }
    }
}

func tr(_ key: String) -> String {
    switch Localizer.active {
    case .ko: Strings.ko[key] ?? key
    case .zh: Strings.zh[key] ?? key
    default: key
    }
}

/// Rebuilds its content when the interface language changes.
struct LocalizedRoot<Content: View>: View {
    @State private var localizer = Localizer.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().id(localizer.language)
    }
}
