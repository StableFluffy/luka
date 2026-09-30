import AppKit
import LukaCore
import SwiftUI

enum CaptionStyle: String, CaseIterable, Sendable {
    case glass, clear, dark
}

enum CaptionVisibility: String, CaseIterable, Sendable {
    /// Captions come and go with listening.
    case whileListening
    /// Captions stay where you left them; toggle by hand.
    case always
}

@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle, connecting, live, paused, reconnecting
        case error(String)
    }

    let store = SessionStore()
    /// The session audio goes into. Captions always show this one.
    private(set) var transcript = Transcript()
    /// The session shown in the transcript window.
    var selectedID: UUID?
    @ObservationIgnored private var autosave: Timer?
    @ObservationIgnored var openTranscript: () -> Void = {}
    @ObservationIgnored var closeTranscript: () -> Void = {}
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored let client = SonioxClient()
    @ObservationIgnored let audio = AudioPipeline()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var idleDisconnect: DispatchWorkItem?
    @ObservationIgnored let feedFile: URL?

    private(set) var status: Status = .idle { didSet { if status != oldValue { followStatusWithCaptions() } } }
    private(set) var level: Float = 0
    private(set) var startedAt: Date?

    var apiKey: String { didSet { SecretStore.save(apiKey) } }

    var mode: TranslationMode { didSet { store(mode.rawValue, "mode"); streamSettingsChanged() } }
    /// Soniox code, or "auto".
    var source: String { didSet { store(source, "source"); streamSettingsChanged() } }
    var target: String { didSet { store(target, "target"); streamSettingsChanged() } }
    var languageA: String { didSet { store(languageA, "languageA"); streamSettingsChanged() } }
    var languageB: String { didSet { store(languageB, "languageB"); streamSettingsChanged() } }
    var context: String { didSet { store(context, "context") } }
    var audioSource: AudioSource { didSet { store(audioSource.rawValue, "audioSource"); audioSourceChanged() } }

    var captionLines: Int { didSet { store(captionLines, "captionLines") } }
    var captionFontSize: Double { didSet { store(captionFontSize, "captionFontSize") } }
    var captionShowsOriginal: Bool { didSet { store(captionShowsOriginal, "captionShowsOriginal") } }
    var captionStyle: CaptionStyle { didSet { store(captionStyle.rawValue, "captionStyle") } }
    var captionPinned: Bool { didSet { store(captionPinned, "captionPinned") } }
    var transcriptFontSize: Double { didSet { store(transcriptFontSize, "transcriptFontSize") } }
    var transcriptShowsOriginal: Bool { didSet { store(transcriptShowsOriginal, "transcriptShowsOriginal") } }
    var transcriptPinned: Bool { didSet { store(transcriptPinned, "transcriptPinned") } }

    var showsInDock: Bool { didSet { store(showsInDock, "showsInDock"); applyActivationPolicy() } }

    var captionVisibility: CaptionVisibility {
        didSet {
            store(captionVisibility.rawValue, "captionVisibility")
            captionsHiddenByUser = false
            followStatusWithCaptions()
        }
    }
    private(set) var captionsVisible: Bool
    @ObservationIgnored private var captionsHiddenByUser = false
    @ObservationIgnored private var captionsAutoHide: DispatchWorkItem?
    var transcriptVisible = false
    var locked = false
    var renaming: RenameRequest?
    var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    static let captionLineRange = 1...6
    static let captionFontRange = 14.0...64.0
    static let transcriptFontRange = 11.0...28.0

    init() {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        apiKey = SecretStore.read() ?? env["SONIOX_API_KEY"] ?? ""
        let preferred = Localizer.shared.resolved.rawValue
        mode = TranslationMode(rawValue: d.string(forKey: "mode") ?? "") ?? .translate
        source = d.string(forKey: "source") ?? "auto"
        target = d.string(forKey: "target") ?? preferred
        languageA = d.string(forKey: "languageA") ?? (preferred == "en" ? "ko" : "en")
        languageB = d.string(forKey: "languageB") ?? preferred
        context = d.string(forKey: "context") ?? ""
        audioSource = AudioSource(rawValue: d.string(forKey: "audioSource") ?? "") ?? .system
        captionLines = d.object(forKey: "captionLines") as? Int ?? 2
        captionFontSize = d.object(forKey: "captionFontSize") as? Double ?? 24
        captionShowsOriginal = d.bool(forKey: "captionShowsOriginal")
        captionStyle = CaptionStyle(rawValue: d.string(forKey: "captionStyle") ?? "") ?? .glass
        captionPinned = d.object(forKey: "captionPinned") as? Bool ?? true
        transcriptFontSize = d.object(forKey: "transcriptFontSize") as? Double ?? 15
        transcriptShowsOriginal = d.object(forKey: "transcriptShowsOriginal") as? Bool ?? true
        transcriptPinned = d.bool(forKey: "transcriptPinned")
        showsInDock = d.object(forKey: "showsInDock") as? Bool ?? true
        let visibility = CaptionVisibility(rawValue: d.string(forKey: "captionVisibility") ?? "") ?? .whileListening
        captionVisibility = visibility
        captionsVisible = visibility == .always ? d.object(forKey: "captionsVisible") as? Bool ?? true : false

        let args = ProcessInfo.processInfo.arguments
        feedFile = args.firstIndex(of: "--feed").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }

        client.onEvent = { [weak self] in self?.handle($0) }
        client.carryover = { [weak self] in self?.transcript.recentContext() }
        audio.onChunk = { [weak self] data, level in
            Task { @MainActor in
                guard let self else { return }
                self.client.send(audio: data)
                self.level = level
            }
        }
        store.track(transcript)
        selectedID = transcript.id
        autosave = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveLive() }
        }
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(showsInDock ? .regular : .accessory)
    }

    private func store(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: Session

    var hasKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }
    var isListening: Bool { status == .live || status == .connecting || status == .reconnecting }

    var sessionConfig: SessionConfig {
        SessionConfig(mode: mode, source: source == "auto" ? nil : source, target: target,
                      languageA: languageA, languageB: languageB, context: context)
    }

    func toggleListening() {
        if isListening { pause() } else { start() }
    }

    func start() {
        guard hasKey else {
            show(tr("Add your Soniox API key in Settings first."))
            return
        }
        idleDisconnect?.cancel()
        if !client.isOpen {
            status = .connecting
            client.connect(apiKey: apiKey.trimmingCharacters(in: .whitespaces), config: sessionConfig)
        } else {
            status = .live
        }
        if startedAt == nil { startedAt = .now }
        Task {
            do {
                try await audio.start(audioSource, feedFile: feedFile)
            } catch {
                client.disconnect()
                status = .error(error.localizedDescription)
            }
        }
    }

    func pause() {
        audio.stop()
        level = 0
        guard client.isOpen else {
            status = .idle
            return
        }
        client.send(audio: AudioPipeline.silence(milliseconds: 300))
        client.finalize()
        status = .paused
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.status == .paused else { return }
            self.client.disconnect()
        }
        idleDisconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: work)
    }

    /// Saves the current session and opens a fresh one.
    func newSession(start startNow: Bool = false) {
        endSession()
        if !transcript.lines.isEmpty || transcript.id != selectedID {
            transcript = Transcript()
            store.track(transcript)
        }
        selectedID = transcript.id
        if startNow { start() }
    }

    /// Makes an older session the live one and starts listening into it.
    func continueSession(_ t: Transcript) {
        if t.id != transcript.id {
            endSession()
            transcript = t
        }
        selectedID = t.id
        start()
    }

    /// Stops listening and closes the stream. Starting again continues the same session.
    func endSession() {
        audio.stop()
        client.disconnect()
        idleDisconnect?.cancel()
        level = 0
        status = .idle
        startedAt = nil
        renaming = nil
        transcript.clearProvisional()
        store.save(transcript)
    }

    func saveLive() {
        store.save(transcript)
    }

    var selectedTranscript: Transcript? {
        guard let id = selectedID else { return nil }
        return id == transcript.id ? transcript : store.transcript(id)
    }

    func isLive(_ t: Transcript) -> Bool { t.id == transcript.id }

    func deleteSession(_ id: UUID) {
        if id == transcript.id {
            endSession()
            transcript = Transcript()
            store.track(transcript)
        }
        store.delete(id)
        if selectedID == id { selectedID = transcript.id }
    }

    func title(_ t: Transcript) -> String {
        t.title.isEmpty ? Self.defaultTitle(t.createdAt) : t.title
    }

    static func defaultTitle(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localizer.shared.locale))
    }

    func copy(_ t: Transcript) {
        let text = t.plainText(name: { self.speakerName($0, in: t) }, includeOriginal: transcriptShowsOriginal)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(tr("Copied transcript"))
    }

    private func handle(_ event: SonioxClient.Event) {
        switch event {
        case .connected:
            transcript.beginStream()
            if status == .connecting || status == .reconnecting { status = .live }
        case .response(let response):
            transcript.ingest(response)
        case .reconnecting:
            if status != .paused { status = .reconnecting }
        case .failed(let error):
            audio.stop()
            level = 0
            status = .error(Self.message(for: error))
        }
    }

    private func streamSettingsChanged() {
        guard client.isOpen else { return }
        let resume = isListening
        client.disconnect()
        transcript.clearProvisional()
        if resume {
            status = .connecting
            client.connect(apiKey: apiKey, config: sessionConfig)
        } else {
            status = .idle
        }
    }

    private func audioSourceChanged() {
        guard audio.isRunning else { return }
        Task {
            do {
                try await audio.start(audioSource, feedFile: feedFile)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    private static func message(for error: SonioxClient.SonioxError) -> String {
        switch error {
        case .invalidKey: tr("Soniox rejected the API key.")
        case .noCredits: tr("Your Soniox account is out of credits.")
        case .rateLimited: tr("Soniox is rate limiting this key. Try again in a moment.")
        case .config(let m): String(format: tr("Soniox didn’t accept the settings: %@"), m)
        case .network(let m): String(format: tr("Connection lost: %@"), m)
        }
    }

    // MARK: Presentation

    func show(_ message: String) {
        noticeTask?.cancel()
        withAnimation(.smooth) { notice = message }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { notice = nil }
        }
    }

    func speakerName(_ id: SpeakerID?, in t: Transcript? = nil) -> String {
        guard let speaker = (t ?? transcript).speaker(id) else { return "" }
        return speaker.name.isEmpty ? String(format: tr("Speaker %d"), speaker.ordinal) : speaker.name
    }

    // MARK: Caption visibility

    /// The user showing or hiding captions by hand.
    func setCaptions(_ visible: Bool) {
        captionsAutoHide?.cancel()
        withAnimation(.smooth) { captionsVisible = visible }
        if captionVisibility == .always {
            store(visible, "captionsVisible")
        } else {
            // Hiding mid-session sticks until the next session.
            captionsHiddenByUser = !visible && status != .idle
        }
    }

    private func followStatusWithCaptions() {
        guard captionVisibility == .whileListening else { return }
        captionsAutoHide?.cancel()
        switch status {
        case .connecting, .live, .reconnecting:
            if !captionsHiddenByUser { captionsVisible = true }
        case .error:
            captionsVisible = true
        case .paused:
            hideCaptions(after: 60, unlessStatusChanges: .paused)
        case .idle:
            captionsHiddenByUser = false
            // Leave the last lines up long enough to finish reading them.
            hideCaptions(after: 4, unlessStatusChanges: .idle)
        }
    }

    private func hideCaptions(after seconds: Double, unlessStatusChanges expected: Status) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.status == expected, self.captionVisibility == .whileListening else { return }
            self.captionsVisible = false
        }
        captionsAutoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func lock(_ on: Bool) {
        locked = on
        show(on ? tr("Captions locked · ⌃⌥L to unlock") : tr("Captions unlocked"))
    }

    func toggleTranscriptWindow() {
        if transcriptVisible && NSApp.isActive { closeTranscript() } else { openTranscript() }
    }

    func renameCurrentSpeaker() {
        guard let current = transcript.currentSpeaker else {
            show(tr("No one has spoken yet."))
            return
        }
        let transcriptIsKey = NSApp.keyWindow?.identifier?.rawValue.hasPrefix("transcript") == true
        NSApp.activate()
        renaming = RenameRequest(session: transcript.id, id: current, place: captionsVisible && !transcriptIsKey ? .caption : .transcript(turn: nil))
    }

    func adjustFontSize(_ delta: Double, captions: Bool) {
        if captions {
            captionFontSize = (captionFontSize + delta * 2).clamped(to: Self.captionFontRange)
        } else {
            transcriptFontSize = (transcriptFontSize + delta).clamped(to: Self.transcriptFontRange)
        }
    }

    func adjustLines(_ delta: Int) {
        captionLines = (captionLines + delta).clamped(to: Self.captionLineRange)
    }

    var languageSummary: String {
        let locale = Localizer.shared.locale
        let name = { (code: String) in Languages.name(code, in: locale) }
        switch mode {
        case .translate: return "\(source == "auto" ? tr("Auto") : name(source)) → \(name(target))"
        case .twoWay: return "\(name(languageA)) ⇄ \(name(languageB))"
        case .transcribe: return source == "auto" ? tr("Transcribe") : name(source)
        }
    }

    func exportTranscript(_ t: Transcript? = nil) {
        guard let t = t ?? selectedTranscript else { return }
        let panel = NSSavePanel()
        let name = title(t).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        panel.nameFieldStringValue = "\(name).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = t.markdown(title: title(t), name: { self.speakerName($0, in: t) }, includeOriginal: true)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            show(error.localizedDescription)
        }
    }
}

struct RenameRequest: Identifiable, Equatable {
    enum Place: Equatable {
        case caption
        /// `nil` means the speaker's latest turn.
        case transcript(turn: Int?)
    }
    let session: UUID
    let id: SpeakerID
    let place: Place
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
