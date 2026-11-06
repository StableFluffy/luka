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
        /// Paused by itself because it went quiet; capture keeps running locally to notice sound again.
        case standby
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
    @ObservationIgnored let client = SonioxStreams()
    @ObservationIgnored let audio = AudioPipeline()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var idleDisconnect: DispatchWorkItem?
    @ObservationIgnored private var quiet: QuietGate
    /// The last 2 s heard during standby, sent on waking so the first words aren't lost.
    @ObservationIgnored private var preroll: [Data] = []
    @ObservationIgnored let feedFile: URL?

    private(set) var status: Status = .idle { didSet { if status != oldValue { followStatusWithCaptions() } } }
    private(set) var level: Float = 0
    private(set) var startedAt: Date?

    var apiKey: String {
        didSet {
            SecretStore.save(apiKey)
            if apiKey != oldValue { checkKey(after: .milliseconds(600)) }
        }
    }
    /// Where the key's Soniox project lives. Found from the key, never chosen.
    private(set) var region: SonioxRegion {
        didSet {
            store(region.rawValue, "region")
            if region != oldValue { streamSettingsChanged() }
        }
    }

    var mode: TranslationMode { didSet { store(mode.rawValue, "mode"); streamSettingsChanged() } }
    /// Soniox code, or "auto".
    var source: String { didSet { store(source, "source"); streamSettingsChanged() } }
    var target: String { didSet { store(target, "target"); streamSettingsChanged() } }
    var languageA: String { didSet { store(languageA, "languageA"); streamSettingsChanged() } }
    var languageB: String { didSet { store(languageB, "languageB"); streamSettingsChanged() } }
    var languageC: String { didSet { store(languageC, "languageC"); streamSettingsChanged() } }
    var context: String { didSet { store(context, "context") } }
    var audioSource: AudioSource { didSet { store(audioSource.rawValue, "audioSource"); audioSourceChanged() } }
    /// Core Audio UID of the chosen input device; nil follows the system default.
    var microphone: String? {
        didSet {
            guard microphone != oldValue else { return }
            if let microphone { store(microphone, "microphone") } else { defaults.removeObject(forKey: "microphone") }
            if audioSource != .system { audioSourceChanged() }
        }
    }
    var pausesWhenQuiet: Bool {
        didSet {
            store(pausesWhenQuiet, "pausesWhenQuiet")
            quiet.reset()
            if !pausesWhenQuiet, status == .standby { wake() }
        }
    }

    var captionLines: Int { didSet { store(captionLines, "captionLines") } }
    var captionFontSize: Double { didSet { store(captionFontSize, "captionFontSize") } }
    var captionShowsOriginal: Bool { didSet { store(captionShowsOriginal, "captionShowsOriginal") } }
    /// In three-way mode, the one translation captions show; empty shows them all.
    var captionLanguage: String { didSet { store(captionLanguage, "captionLanguage") } }
    /// `captionLanguage` when it applies: three-way mode, and still one of its languages.
    var captionLanguageFilter: String? {
        mode == .threeWay && sessionConfig.threeWayLanguages.contains(captionLanguage) ? captionLanguage : nil
    }
    var captionStyle: CaptionStyle { didSet { store(captionStyle.rawValue, "captionStyle") } }
    var captionPinned: Bool { didSet { store(captionPinned, "captionPinned") } }
    var transcriptFontSize: Double { didSet { store(transcriptFontSize, "transcriptFontSize") } }
    var transcriptShowsOriginal: Bool { didSet { store(transcriptShowsOriginal, "transcriptShowsOriginal") } }
    var transcriptPinned: Bool { didSet { store(transcriptPinned, "transcriptPinned") } }
    var presenterFontSize: Double { didSet { store(presenterFontSize, "presenterFontSize") } }

    var showsInDock: Bool { didSet { store(showsInDock, "showsInDock"); applyActivationPolicy() } }
    var liquidGlass: Bool { didSet { store(liquidGlass, "liquidGlass") } }
    /// Liquid Glass needs macOS 26; before that, and when turned off, Luka draws system materials.
    var usesGlass: Bool { LukaGlassSupport.available && liquidGlass }

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
    var presenterVisible = false
    var locked = false
    var renaming: RenameRequest?
    var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    static let captionLineRange = 1...6
    static let captionFontRange = 14.0...64.0
    static let transcriptFontRange = 11.0...28.0
    static let presenterFontRange = 20.0...96.0

    init() {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        apiKey = SecretStore.read() ?? env["SONIOX_API_KEY"] ?? ""
        let storedRegion = SonioxRegion(rawValue: d.string(forKey: "region") ?? "")
        region = storedRegion ?? .us
        let preferred = Localizer.shared.resolved.rawValue
        mode = TranslationMode(rawValue: d.string(forKey: "mode") ?? "") ?? .translate
        source = d.string(forKey: "source") ?? "auto"
        target = d.string(forKey: "target") ?? preferred
        let a = d.string(forKey: "languageA") ?? (preferred == "en" ? "ko" : "en")
        let b = d.string(forKey: "languageB") ?? preferred
        languageA = a
        languageB = b
        languageC = d.string(forKey: "languageC") ?? (["en", "ko", "zh"].first { $0 != a && $0 != b } ?? "ja")
        context = d.string(forKey: "context") ?? ""
        audioSource = AudioSource(rawValue: d.string(forKey: "audioSource") ?? "") ?? .system
        microphone = d.string(forKey: "microphone")
        pausesWhenQuiet = d.object(forKey: "pausesWhenQuiet") == nil ? true : d.bool(forKey: "pausesWhenQuiet")
        quiet = QuietGate(sleepAfterSeconds: d.object(forKey: "quietSeconds") == nil ? 180 : d.integer(forKey: "quietSeconds"))
        captionLines = d.object(forKey: "captionLines") as? Int ?? 2
        captionFontSize = d.object(forKey: "captionFontSize") as? Double ?? 24
        captionShowsOriginal = d.bool(forKey: "captionShowsOriginal")
        captionLanguage = d.string(forKey: "captionLanguage") ?? ""
        captionStyle = CaptionStyle(rawValue: d.string(forKey: "captionStyle") ?? "") ?? .glass
        captionPinned = d.object(forKey: "captionPinned") as? Bool ?? true
        transcriptFontSize = d.object(forKey: "transcriptFontSize") as? Double ?? 15
        transcriptShowsOriginal = d.object(forKey: "transcriptShowsOriginal") as? Bool ?? true
        transcriptPinned = d.bool(forKey: "transcriptPinned")
        presenterFontSize = d.object(forKey: "presenterFontSize") as? Double ?? 40
        showsInDock = d.object(forKey: "showsInDock") as? Bool ?? true
        liquidGlass = d.object(forKey: "liquidGlass") == nil ? true : d.bool(forKey: "liquidGlass")
        let visibility = CaptionVisibility(rawValue: d.string(forKey: "captionVisibility") ?? "") ?? .whileListening
        captionVisibility = visibility
        captionsVisible = visibility == .always ? d.object(forKey: "captionsVisible") as? Bool ?? true : false

        let args = ProcessInfo.processInfo.arguments
        feedFile = args.firstIndex(of: "--feed").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }

        client.onEvent = { [weak self] lane, event in
            if lane == 0 { self?.handle(event) } else { self?.handleTranslation(event, lane: lane) }
        }
        client.carryover = { [weak self] in self?.transcript.recentContext() }
        audio.onChunk = { [weak self] data, level in
            Task { @MainActor in self?.heard(data, level: level) }
        }
        store.track(transcript)
        selectedID = transcript.id
        if hasKey, storedRegion == nil { checkKey(after: .zero) }
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
    var isListening: Bool { [.live, .connecting, .reconnecting, .standby].contains(status) }

    var sessionConfig: SessionConfig {
        SessionConfig(mode: mode, source: source == "auto" ? nil : source, target: target,
                      languageA: languageA, languageB: languageB, languageC: languageC, context: context)
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
        quiet.reset()
        preroll.removeAll()
        retriedRegion = false
        if !client.isOpen {
            status = .connecting
            connectStream()
        } else {
            status = .live
        }
        if startedAt == nil { startedAt = .now }
        transcript.markStarted()
        Task {
            do {
                try await audio.start(audioSource, microphone: microphone, feedFile: feedFile)
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
        disconnectSoon()
    }

    /// Soniox bills while a stream is open, so a pause keeps it only long enough for a quick resume.
    private func disconnectSoon() {
        idleDisconnect?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, [.paused, .standby].contains(self.status) else { return }
            self.client.disconnect()
        }
        idleDisconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func heard(_ data: Data, level: Float) {
        self.level = level
        if findingRegion {
            // Held while the key's region is looked up, then sent, like waking from standby.
            preroll.append(data)
            if preroll.count > 50 { preroll.removeFirst() }
            return
        }
        guard pausesWhenQuiet else {
            client.send(audio: data)
            return
        }
        if status == .standby {
            preroll.append(data)
            if preroll.count > 20 { preroll.removeFirst() }
            if quiet.wake(level: level) { wake() }
            return
        }
        client.send(audio: data)
        if status == .live, quiet.listen(level: level) { standBy() }
    }

    private func standBy() {
        AudioLog.write("quiet for \(quiet.sleepAfter / 10) s: standby")
        client.finalize()
        status = .standby
        quiet.reset()
        disconnectSoon()
    }

    private func wake() {
        AudioLog.write("sound again: resuming")
        idleDisconnect?.cancel()
        quiet.reset()
        if client.isOpen {
            status = .live
        } else {
            status = .connecting
            connectStream()
        }
        preroll.forEach { client.send(audio: $0) }
        preroll.removeAll()
    }

    /// Saves the current session and opens a fresh one.
    func newSession(start startNow: Bool = false) {
        endSession()
        if transcript.hasStarted || transcript.id != selectedID {
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
        t.title.isEmpty ? Self.defaultTitle(t) : t.title
    }

    /// Until listening starts, a session has no meaningful time, so it is just "New Session".
    static func defaultTitle(_ t: Transcript) -> String {
        t.hasStarted ? defaultTitle(t.createdAt) : tr("New Session")
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
        case .response(let response, let baseMs):
            if response.tokens.contains(where: { !$0.isMarker }) { quiet.heardSpeech() }
            transcript.ingest(response, baseMs: baseMs)
        case .reconnecting:
            if ![.paused, .standby].contains(status) { status = .reconnecting }
        case .failed(let error):
            fail(error)
        }
    }

    /// Events from three-way mode's extra streams, which only add translations.
    private func handleTranslation(_ event: SonioxClient.Event, lane: Int) {
        switch event {
        case .response(let response, let baseMs):
            transcript.ingestTranslation(response, lane: lane, baseMs: baseMs)
        case .failed(let error):
            fail(error)
        case .connected, .reconnecting:
            break
        }
    }

    private func fail(_ error: SonioxClient.SonioxError) {
        if error == .invalidKey {
            // Every stream reports the same rejection; the first one decides.
            if findingRegion { return }
            if !retriedRegion {
                retryInKeysRegion()
                return
            }
        }
        audio.stop()
        client.disconnect()
        level = 0
        status = .error(Self.message(for: error))
    }

    private func streamSettingsChanged() {
        guard client.isOpen else { return }
        let resume = isListening
        client.disconnect()
        transcript.clearProvisional()
        // Standby wakes into a fresh stream with the new settings.
        if status == .standby { return }
        if resume {
            status = .connecting
            connectStream()
        } else {
            status = .idle
        }
    }

    // MARK: Key and region

    enum KeyState: Equatable {
        case idle, checking, invalid, unreachable
    }

    private(set) var keyState: KeyState = .idle
    @ObservationIgnored private var keyCheck: Task<Void, Never>?
    /// The key `keyCheck` already covers, so saving a verified key doesn't check it again.
    @ObservationIgnored private var checkedKey: String?
    @ObservationIgnored private var findingRegion = false
    @ObservationIgnored private var retriedRegion = false

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespaces) }

    /// Checks the key in every region and keeps the one that accepts it.
    private func checkKey(after delay: Duration) {
        let key = trimmedKey
        guard key != checkedKey else { return }
        keyCheck?.cancel()
        guard !key.isEmpty else {
            keyState = .idle
            keyCheck = nil
            return
        }
        keyState = .checking
        keyCheck = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let result = await KeyCheck.run(key)
            guard !Task.isCancelled else { return }
            apply(result, for: key)
            keyCheck = nil
        }
    }

    private func apply(_ result: KeyCheck.Result, for key: String) {
        checkedKey = key
        retriedRegion = false
        AudioLog.write("key check: \(result)")
        switch result {
        case .region(let found):
            region = found
            keyState = .idle
        case .invalid:
            keyState = .invalid
        case .unreachable:
            keyState = .unreachable
        }
    }

    /// The first-run key field: keeps the key only if Soniox accepts it somewhere.
    func submitKey(_ key: String) async -> KeyCheck.Result {
        keyCheck?.cancel()
        keyState = .checking
        let result = await KeyCheck.run(key)
        apply(result, for: key)
        if result != .invalid { apiKey = key }
        return result
    }

    /// Opens the streams, after a key check in flight has settled the region.
    private func connectStream() {
        guard let pending = keyCheck else {
            client.connect(apiKey: trimmedKey, region: region, config: sessionConfig)
            return
        }
        Task {
            await pending.value
            guard status == .connecting else { return }
            client.connect(apiKey: trimmedKey, region: region, config: sessionConfig)
        }
    }

    /// A rejected key may belong to another region: look it up once and reconnect there.
    private func retryInKeysRegion() {
        findingRegion = true
        retriedRegion = true
        client.disconnect()
        status = .connecting
        let key = trimmedKey
        preroll.removeAll()
        Task {
            let result = await KeyCheck.run(key)
            findingRegion = false
            guard status == .connecting else { return }
            if case .region(let found) = result, found != region {
                AudioLog.write("key belongs to region \(found.rawValue): reconnecting")
                apply(result, for: key)
                connectStream()
                preroll.forEach { client.send(audio: $0) }
                preroll.removeAll()
                return
            }
            if result == .invalid { keyState = .invalid }
            fail(result == .unreachable ? .network(tr("Couldn’t reach Soniox.")) : .invalidKey)
        }
    }

    private func audioSourceChanged() {
        guard audio.isRunning else { return }
        Task {
            do {
                try await audio.start(audioSource, microphone: microphone, feedFile: feedFile)
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    private static func message(for error: SonioxClient.SonioxError) -> String {
        switch error {
        case .invalidKey: tr("Soniox doesn’t recognize this API key. Check it in Settings.")
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
        case .paused, .standby:
            hideCaptions(after: 60, unlessStatusChanges: status)
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

    func adjustFontSize(_ delta: Double, captions: Bool, presenter: Bool = false) {
        if presenter {
            presenterFontSize = (presenterFontSize + delta * 4).clamped(to: Self.presenterFontRange)
        } else if captions {
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
        case .threeWay: return sessionConfig.threeWayLanguages.map(name).joined(separator: " · ")
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
