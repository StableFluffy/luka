import LukaCore
import SwiftUI

enum SpeakerPalette {
    static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .indigo, .mint]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

extension AppModel {
    func speakerColor(_ id: SpeakerID?, in t: Transcript? = nil) -> Color {
        guard let s = (t ?? transcript).speaker(id) else { return .secondary }
        return SpeakerPalette.color(s.colorIndex)
    }
}

extension EnvironmentValues {
    /// The session a view is showing; falls back to the live one.
    @Entry var session: Transcript?
}

/// Rename, recolor and merge one speaker. Edits apply as you type.
struct SpeakerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.session) private var session
    let id: SpeakerID
    @FocusState private var focused: Bool

    var body: some View {
        let transcript = session ?? model.transcript
        if let speaker = transcript.speaker(id) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle().fill(SpeakerPalette.color(speaker.colorIndex)).frame(width: 12, height: 12)
                    TextField(String(format: tr("Speaker %d"), speaker.ordinal), text: Binding(
                        get: { transcript.speaker(id)?.name ?? "" },
                        set: { transcript.rename(id, to: $0) }))
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .focused($focused)
                        .onSubmit { dismiss(); model.renaming = nil }
                }
                HStack(spacing: 8) {
                    ForEach(SpeakerPalette.colors.indices, id: \.self) { i in
                        Button { withAnimation(.smooth) { transcript.recolor(id, to: i) } } label: {
                            Circle()
                                .fill(SpeakerPalette.colors[i])
                                .frame(width: 18, height: 18)
                                .overlay { if i == speaker.colorIndex { Circle().strokeBorder(.white, lineWidth: 2).padding(3) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: "\(i + 1)"))
                    }
                }
                let others = transcript.visibleSpeakers.filter { $0.id != speaker.id }
                if !others.isEmpty {
                    Divider()
                    Menu {
                        ForEach(others) { other in
                            Button(model.speakerName(other.id, in: transcript)) {
                                withAnimation(.smooth) { transcript.merge(id, into: other.id) }
                                model.renaming = nil
                            }
                        }
                    } label: {
                        Label(tr("Same person as…"), systemImage: "person.2.badge.plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Text(tr("Merge when one voice was split into two speakers."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: 280)
            .onAppear { focused = true }
        }
    }
}

struct SpeakerChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.session) private var session
    let id: SpeakerID?
    var turn: Int?
    var font: Font = .subheadline.weight(.semibold)

    var body: some View {
        let t = session ?? model.transcript
        Button {
            if let id { model.renaming = RenameRequest(session: t.id, id: t.canonical(id), place: .transcript(turn: turn)) }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(model.speakerColor(id, in: t)).frame(width: 7, height: 7)
                Text(model.speakerName(id, in: t))
                    .font(font)
                    .foregroundStyle(model.speakerColor(id, in: t))
                    .contentTransition(.interpolate)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tr("Rename speaker"))
    }
}

struct LanguagePicker: View {
    @Environment(AppModel.self) private var model
    @Namespace private var modeSelection

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                modeTile(.translate, "globe", tr("Translate"))
                modeTile(.twoWay, "arrow.left.arrow.right", tr("Two-way"))
                modeTile(.transcribe, "text.quote", tr("Transcribe"))
            }

            Group {
                switch model.mode {
                case .translate:
                    HStack(alignment: .bottom, spacing: 8) {
                        LanguageField(label: tr("From"), selection: $model.source, allowsAuto: true)
                        swapButton(disabled: model.source == "auto") {
                            let s = model.source
                            model.source = model.target
                            model.target = s
                        }
                        LanguageField(label: tr("To"), selection: $model.target, allowsAuto: false)
                    }
                case .twoWay:
                    HStack(alignment: .bottom, spacing: 8) {
                        LanguageField(label: tr("Between"), selection: $model.languageA, allowsAuto: false)
                        swapButton(disabled: false) {
                            let a = model.languageA
                            model.languageA = model.languageB
                            model.languageB = a
                        }
                        LanguageField(label: tr("and"), selection: $model.languageB, allowsAuto: false)
                    }
                case .transcribe:
                    LanguageField(label: tr("Language"), selection: $model.source, allowsAuto: true)
                }
            }
            .transition(.opacity)

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .padding(16)
        .frame(width: 360)
        .animation(.smooth(duration: 0.25), value: model.mode)
    }

    private func modeTile(_ mode: TranslationMode, _ symbol: String, _ title: String) -> some View {
        let selected = model.mode == mode
        return Button {
            model.mode = mode
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolEffect(.bounce, value: selected)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.45))
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.gradient)
                        .matchedGeometryEffect(id: "mode", in: modeSelection)
                }
            }
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func swapButton(disabled: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.smooth) { action() } } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(ToolbarHoverStyle())
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .help(tr("Swap"))
    }

    private var footnote: String {
        switch model.mode {
        case .translate: tr("Speech in any language is translated into one language.")
        case .twoWay: tr("For conversations: each side is translated into the other’s language.")
        case .transcribe: tr("Writes down what’s said, without translating.")
        }
    }
}

private struct LanguageField: View {
    let label: String
    @Binding var selection: String
    let allowsAuto: Bool

    var body: some View {
        let locale = Localizer.shared.locale
        let languages = Languages.ordered(in: locale)
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Menu {
                Picker(selection: $selection) {
                    if allowsAuto {
                        Label(tr("Detect automatically"), systemImage: "sparkles").tag("auto")
                        Divider()
                    }
                    ForEach(languages.prefix(Languages.pinned.count), id: \.self) { Text(Languages.name($0, in: locale)).tag($0) }
                    Divider()
                    ForEach(languages.dropFirst(Languages.pinned.count), id: \.self) { Text(Languages.name($0, in: locale)).tag($0) }
                } label: { EmptyView() }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    if selection == "auto" {
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                    }
                    Text(selection == "auto" ? tr("Auto") : Languages.name(selection, in: locale))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 9, style: .continuous))
                .contentShape(.rect(cornerRadius: 9))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SourcePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker(tr("Listen to"), selection: $model.audioSource) {
            ForEach(AudioSource.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
        }
    }
}

/// Mac audio / both / microphone as one sliding switch.
struct SourceSwitch: View {
    @Environment(AppModel.self) private var model
    var height: CGFloat = 40
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AudioSource.switchOrder, id: \.self) { source in
                let selected = model.audioSource == source
                Button {
                    withAnimation(.smooth(duration: 0.28)) { model.audioSource = source }
                } label: {
                    source.icon
                        .font(.system(size: height * 0.32, weight: .semibold))
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: height * 1.1, height: height - 8)
                        .background {
                            if selected {
                                Capsule().fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(source.title)
                .accessibilityLabel(source.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
    }
}

extension AudioSource {
    static let switchOrder: [AudioSource] = [.system, .both, .microphone]

    @ViewBuilder var icon: some View {
        switch self {
        case .system: Image(systemName: "speaker.wave.2.fill")
        case .microphone: Image(systemName: "mic.fill")
        case .both:
            HStack(spacing: 1) {
                Image(systemName: "speaker.wave.2.fill")
                Image(systemName: "mic.fill")
            }
            .imageScale(.small)
        }
    }

    var title: String {
        switch self {
        case .system: tr("Mac Audio")
        case .microphone: tr("Microphone")
        case .both: tr("Mac Audio + Microphone")
        }
    }

    var symbol: String {
        switch self {
        case .system: "speaker.wave.2"
        case .microphone: "mic"
        case .both: "waveform.badge.mic"
        }
    }
}

/// A waveform that fills with the input level, so it reads as "live audio" at any volume.
struct LevelBars: View {
    var level: Float
    var active: Bool
    var color: Color = .primary

    var body: some View {
        Image(systemName: "waveform", variableValue: active ? Double(0.25 + 0.75 * min(1, level * 1.3)) : 0.25)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .font(.system(size: 13, weight: .semibold))
            .animation(.smooth(duration: 0.12), value: level)
    }
}

extension AppModel.Status {
    var label: String {
        switch self {
        case .idle: tr("Ready")
        case .connecting: tr("Connecting…")
        case .live: tr("Listening")
        case .paused: tr("Paused")
        case .reconnecting: tr("Reconnecting…")
        case .error(let message): message
        }
    }
}

/// Luka's system-wide shortcuts. ⌃⌥ + a letter works from any app; Fn is left alone.
enum GlobalShortcut: CaseIterable {
    case newSession, toggle, captions, transcript, lock

    var keys: [String] {
        switch self {
        case .newSession: ["⌃", "⌥", "N"]
        case .toggle: ["⌃", "⌥", "R"]
        case .captions: ["⌃", "⌥", "C"]
        case .transcript: ["⌃", "⌥", "T"]
        case .lock: ["⌃", "⌥", "L"]
        }
    }

    var title: String {
        switch self {
        case .newSession: tr("New transcription")
        case .toggle: tr("Start / Pause")
        case .captions: tr("Show / hide captions")
        case .transcript: tr("Show / hide transcript")
        case .lock: tr("Lock / unlock captions")
        }
    }

    var text: String { keys.joined() }
}

struct KeyCaps: View {
    let keys: [String]
    var size: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys.indices, id: \.self) { i in
                Text(keys[i])
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .frame(minWidth: size * 1.9, minHeight: size * 1.9)
                    .padding(.horizontal, keys[i].count > 1 ? 5 : 0)
                    .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: size * 0.45))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.45).strokeBorder(.separator, lineWidth: 0.5))
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// Shown in empty spaces so the shortcuts are learned by looking, not by reading Settings.
struct ShortcutGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Works from any app"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.bottom, 6)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(GlobalShortcut.allCases, id: \.self) { shortcut in
                    GridRow {
                        KeyCaps(keys: shortcut.keys)
                            .gridColumnAlignment(.trailing)
                        Text(shortcut.title)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    KeyCaps(keys: ["⌘", "E"])
                    Text(tr("Name whoever is speaking"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 16))
    }
}
