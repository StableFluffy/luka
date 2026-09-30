import LukaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab(tr("General"), systemImage: "gearshape") { GeneralSettings() }
            Tab(tr("Captions"), systemImage: "captions.bubble") { CaptionSettings() }
            Tab(tr("Shortcuts"), systemImage: "command") { ShortcutSettings() }
        }
        .frame(width: 500)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var localizer = Localizer.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(tr("Interface language"), selection: $localizer.language) {
                    ForEach(UILanguage.allCases, id: \.self) { Text(Localizer.displayName($0)).tag($0) }
                }
                Toggle(tr("Open at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do {
                            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            model.show(error.localizedDescription)
                        }
                    }
                Toggle(tr("Show in Dock"), isOn: $model.showsInDock)
            } footer: {
                Text(tr("Luka keeps running in the menu bar, so ⌃⌥N can start a transcription at any time."))
            }
            Section {
                SecureField(tr("API key"), text: $model.apiKey)
                LabeledContent(tr("Model")) { Text(SessionConfig.model).foregroundStyle(.secondary) }
            } header: {
                Text("Soniox")
            } footer: {
                Link(tr("Get a key at console.soniox.com"), destination: URL(string: "https://console.soniox.com")!)
            }
            Section {
                SourcePicker()
                LabeledContent(tr("Languages")) { Text(model.languageSummary).foregroundStyle(.secondary) }
            } footer: {
                Text(tr("Change languages from the globe button while listening."))
            }
            Section {
                TextField(tr("Context"), text: $model.context, prompt: Text(tr("Names, topics, jargon…")), axis: .vertical)
                    .lineLimit(3...6)
            } footer: {
                Text(tr("Helps recognition of names and terms. Applies from the next session."))
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}

private struct CaptionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(tr("Style"), selection: $model.captionStyle) {
                    ForEach(CaptionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent(tr("Text size")) {
                    HStack {
                        Slider(value: $model.captionFontSize, in: AppModel.captionFontRange, step: 2)
                        Text(verbatim: "\(Int(model.captionFontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
                Stepper(value: $model.captionLines, in: AppModel.captionLineRange) {
                    LabeledContent(tr("Lines"), value: "\(model.captionLines)")
                }
                Toggle(tr("Show Original"), isOn: $model.captionShowsOriginal)
                Toggle(tr("Keep on Top"), isOn: $model.captionPinned)
            } footer: {
                Text(tr("Drag the caption’s top or bottom edge to add lines, its sides to resize. Drop it near the center and it snaps."))
            }
            Section(tr("Transcript")) {
                LabeledContent(tr("Text size")) {
                    HStack {
                        Slider(value: $model.transcriptFontSize, in: AppModel.transcriptFontRange, step: 1)
                        Text(verbatim: "\(Int(model.transcriptFontSize))").monospacedDigit().frame(width: 28, alignment: .trailing)
                    }
                }
                Toggle(tr("Show Original"), isOn: $model.transcriptShowsOriginal)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}

private struct ShortcutSettings: View {
    private var local: [(String, [String])] {
        [
            (tr("Start / Pause"), ["⌘", "R"]),
            (tr("Finish Session"), ["⌘", "."]),
            (tr("New Session"), ["⌘", "N"]),
            (tr("Name whoever is speaking"), ["⌘", "E"]),
            (tr("Captions"), ["⌘", "1"]),
            (tr("Show Transcript"), ["⌘", "2"]),
            (tr("Bigger / Smaller Text"), ["⌘", "+", "−"]),
            (tr("More / Fewer Caption Lines"), ["⌘", "↑", "↓"]),
            (tr("Show Original"), ["⌥", "⌘", "O"]),
            (tr("Keep Captions on Top"), ["⌥", "⌘", "T"]),
            (tr("Copy Transcript"), ["⇧", "⌘", "C"]),
            (tr("Export Transcript…"), ["⌘", "S"]),
        ]
    }

    var body: some View {
        Form {
            Section(tr("Works from any app")) {
                ForEach(GlobalShortcut.allCases, id: \.self) { shortcut in
                    LabeledContent(shortcut.title) { KeyCaps(keys: shortcut.keys) }
                }
            }
            Section(tr("In Luka")) {
                ForEach(local, id: \.0) { row in
                    LabeledContent(row.0) { KeyCaps(keys: row.1) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }
}
