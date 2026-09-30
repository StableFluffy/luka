import AppKit
import Carbon.HIToolbox
import LukaCore
import SwiftUI

@main
struct LukaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var localizer = Localizer.shared

    /// The transcript window holds onboarding, so it opens on first launch; afterwards captions lead.
    private static let presentsTranscriptAtLaunch: Bool = {
        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        return firstLaunch || ProcessInfo.processInfo.arguments.contains("--transcript")
    }()

    var body: some Scene {
        let model = delegate.model
        Window("Luka", id: "transcript") {
            TranscriptWindow()
                .environment(model)
                .environment(\.usesGlass, model.usesGlass)
                .id(localizer.language)
        }
        .defaultSize(width: 760, height: 640)
        .defaultPosition(.trailing)
        .defaultLaunchBehavior(Self.presentsTranscriptAtLaunch ? .presented : .suppressed)
        .windowToolbarStyle(.unified)
        .commands { LukaCommands(model: model, localizer: localizer) }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.usesGlass, model.usesGlass)
                .id(localizer.language)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .id(localizer.language)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var captions: CaptionPanelController?
    private let hotKeys = HotKeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let captions = CaptionPanelController(model: model)
        self.captions = captions
        if model.captionsVisible { captions.show() }
        model.applyActivationPolicy()
        let chord = controlKey | optionKey
        hotKeys.register([
            .init(keyCode: kVK_ANSI_N, modifiers: chord) { [model] in model.newSession(start: true) },
            .init(keyCode: kVK_ANSI_R, modifiers: chord) { [model] in model.toggleListening() },
            .init(keyCode: kVK_ANSI_C, modifiers: chord) { [model] in model.setCaptions(!model.captionsVisible) },
            .init(keyCode: kVK_ANSI_T, modifiers: chord) { [model] in model.toggleTranscriptWindow() },
            .init(keyCode: kVK_ANSI_L, modifiers: chord) { [model] in model.lock(!model.locked) },
        ])
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--autostart") { model.start() }
        if let i = args.firstIndex(of: "--finish-after"), args.indices.contains(i + 1), let seconds = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [model] in model.endSession() }
        }
        Snapshot.startIfRequested(model: model)
        Demo.startIfRequested(model: model)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon opens the transcript; captions follow listening on their own.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !model.transcriptVisible { model.openTranscript() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.endSession()
    }
}

/// The menu bar icon. It is always on screen, so it is also where the app picks up
/// SwiftUI's window actions for use from AppKit (hotkeys, the caption panel).
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: model.isListening ? "captions.bubble.fill" : "captions.bubble")
            .onAppear {
                model.openTranscript = {
                    NSApp.activate()
                    openWindow(id: "transcript")
                }
                model.closeTranscript = { dismissWindow(id: "transcript") }
                model.openSettings = {
                    NSApp.activate()
                    openSettings()
                }
            }
    }
}

struct LukaCommands: Commands {
    let model: AppModel
    let localizer: Localizer
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        let _ = localizer.language
        CommandGroup(replacing: .newItem) {
            Button(tr("New Session")) { withAnimation(.smooth) { model.newSession() } }
                .keyboardShortcut("n")
        }
        CommandGroup(replacing: .saveItem) {
            Button(tr("Export Transcript…")) { model.exportTranscript() }
                .keyboardShortcut("s")
                .disabled(model.transcript.lines.isEmpty)
        }
        CommandMenu(tr("Listen")) {
            Button(model.isListening ? tr("Pause") : tr("Start Listening")) { model.toggleListening() }
                .keyboardShortcut("r")
            Button(tr("Finish Session")) { model.endSession() }
                .keyboardShortcut(".")
                .disabled(model.status == .idle)
            Divider()
            Picker(tr("Listen to"), selection: Binding(get: { model.audioSource }, set: { model.audioSource = $0 })) {
                ForEach(AudioSource.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker(tr("Mode"), selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                Text(tr("Translate")).tag(TranslationMode.translate)
                Text(tr("Two-way")).tag(TranslationMode.twoWay)
                Text(tr("Transcribe")).tag(TranslationMode.transcribe)
            }
        }
        CommandMenu(tr("Speakers")) {
            Button(tr("Rename Current Speaker…")) { model.renameCurrentSpeaker() }
                .keyboardShortcut("e")
            let speakers = model.transcript.visibleSpeakers
            if !speakers.isEmpty {
                Divider()
                ForEach(speakers) { speaker in
                    Button(model.speakerName(speaker.id)) {
                        NSApp.activate()
                        model.renaming = RenameRequest(session: model.transcript.id, id: speaker.id, place: model.captionsVisible ? .caption : .transcript(turn: nil))
                    }
                }
            }
        }
        CommandGroup(before: .toolbar) {
            Toggle(tr("Captions"), isOn: Binding(get: { model.captionsVisible }, set: { model.setCaptions($0) }))
                .keyboardShortcut("1")
            Button(model.transcriptVisible ? tr("Hide Transcript") : tr("Show Transcript")) {
                if model.transcriptVisible { dismissWindow(id: "transcript") } else { openWindow(id: "transcript") }
            }
            .keyboardShortcut("2")
            Divider()
            Button(tr("Bigger Text")) { model.adjustFontSize(1, captions: !isTranscriptKey) }
                .keyboardShortcut("+")
            Button(tr("Smaller Text")) { model.adjustFontSize(-1, captions: !isTranscriptKey) }
                .keyboardShortcut("-")
            Button(tr("More Caption Lines")) { model.adjustLines(1) }
                .keyboardShortcut(.upArrow)
            Button(tr("Fewer Caption Lines")) { model.adjustLines(-1) }
                .keyboardShortcut(.downArrow)
            Toggle(tr("Show Original"), isOn: Binding(
                get: { isTranscriptKey ? model.transcriptShowsOriginal : model.captionShowsOriginal },
                set: { if isTranscriptKey { model.transcriptShowsOriginal = $0 } else { model.captionShowsOriginal = $0 } }))
                .keyboardShortcut("o", modifiers: [.command, .option])
            Divider()
            Toggle(tr("Keep Captions on Top"), isOn: Binding(get: { model.captionPinned }, set: { model.captionPinned = $0 }))
                .keyboardShortcut("t", modifiers: [.command, .option])
            Toggle(tr("Lock Captions"), isOn: Binding(get: { model.locked }, set: { model.lock($0) }))
                .keyboardShortcut("l")
            Divider()
        }
    }

    private var isTranscriptKey: Bool {
        NSApp.keyWindow?.identifier?.rawValue.hasPrefix("transcript") == true
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        Button(tr("New Transcription") + "  ⌃⌥N") { model.newSession(start: true) }
        Button((model.isListening ? tr("Pause") : tr("Start Listening")) + "  ⌃⌥R") { model.toggleListening() }
        Text(model.status.label)
        Divider()
        Toggle(tr("Captions"), isOn: Binding(get: { model.captionsVisible }, set: { model.setCaptions($0) }))
        Toggle(tr("Lock Captions"), isOn: Binding(get: { model.locked }, set: { model.lock($0) }))
        Button(tr("Show Transcript")) { model.openTranscript() }
        Divider()
        SourcePicker()
        Divider()
        Button(tr("Settings…")) {
            NSApp.activate()
            openSettings()
        }
        Button(tr("Quit Luka")) { NSApp.terminate(nil) }
    }
}
