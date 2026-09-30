import LukaCore
import SwiftUI

struct CaptionRoot: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?
    /// The language popover lives in its own window, so hovering it doesn't count as hovering the caption.
    @State private var languagesShown = false
    @Namespace private var glass

    private var metrics: CaptionMetrics { CaptionMetrics(fontSize: model.captionFontSize) }

    var body: some View {
        let showToolbar = (hovering || languagesShown || model.notice != nil) && !model.locked
        let showStatus = !showToolbar && model.hasKey && !model.transcript.isEmpty
            && [.connecting, .reconnecting, .paused].contains(model.status)
        // Spacing below the gaps between pieces: they morph out of the caption but don't fuse at rest.
        GlassEffectContainer(spacing: 6) {
            VStack(spacing: CaptionPanelController.toolbarGap) {
                ZStack(alignment: .bottom) {
                    Color.clear
                    if let notice = model.notice {
                        Text(notice)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .glassEffect(.regular, in: .capsule)
                            .glassEffectID("notice", in: glass)
                            .transition(.opacity)
                    } else if showToolbar {
                        CaptionToolbar(namespace: glass, languagesShown: $languagesShown)
                            .onHover { setHover($0) }
                    } else if showStatus {
                        HStack(spacing: 7) {
                            Image(systemName: model.status == .paused ? "pause.fill" : "arrow.trianglehead.2.clockwise")
                                .symbolEffect(.rotate, options: .repeating, isActive: model.status != .paused)
                            Text(model.status.label)
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .glassEffect(.regular, in: .capsule)
                        .glassEffectID("status", in: glass)
                        .transition(.opacity)
                    }
                }
                .frame(height: CaptionPanelController.toolbarHeight)

                CaptionSurface(metrics: metrics)
                    .glassEffect(model.captionStyle.glass, in: .rect(cornerRadius: cornerRadius))
                    .glassEffectID("caption", in: glass)
                    .onHover { setHover($0) }
                    .overlay { ResizeHandles(metrics: metrics) }
                    .environment(\.colorScheme, model.captionStyle == .dark ? .dark : colorScheme)
            }
        }
        .animation(.smooth(duration: 0.3), value: showToolbar)
        .animation(.smooth(duration: 0.3), value: showStatus)
        .animation(.smooth(duration: 0.3), value: model.notice)
        .popover(item: Binding(get: { model.renaming?.place == .caption ? model.renaming : nil },
                               set: { if $0 == nil { model.renaming = nil } }),
                 attachmentAnchor: .rect(.bounds), arrowEdge: .top) { request in
            SpeakerEditor(id: request.id).environment(model)
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var cornerRadius: CGFloat {
        let h = metrics.height(lines: model.captionLines)
        return min(h / 2, 26)
    }

    private func setHover(_ inside: Bool) {
        hideTask?.cancel()
        if inside {
            hovering = true
        } else {
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { hovering = false }
            }
        }
    }
}

extension CaptionStyle {
    var glass: Glass {
        switch self {
        case .glass: .regular
        case .clear: .clear
        case .dark: .regular.tint(.black.opacity(0.5))
        }
    }

    var title: String {
        switch self {
        case .glass: tr("Glass")
        case .clear: tr("Clear")
        case .dark: tr("Dark")
        }
    }
}

struct CaptionSurface: View {
    @Environment(AppModel.self) private var model
    let metrics: CaptionMetrics

    var body: some View {
        GeometryReader { geo in
            let transcript = model.transcript
            let names = transcript.visibleSpeakers.map { model.speakerName($0.id) }
            let gutter = names.isEmpty ? 0 : CaptionLayout.labelWidth(names, metrics: metrics, limit: geo.size.width * 0.26)
            let textWidth = geo.size.width - metrics.horizontalPadding * 2 - (gutter > 0 ? gutter + metrics.gutterSpacing : 0) - 4
            let dual = model.captionShowsOriginal
            let rows = CaptionLayout.rows(
                CaptionLayout.blocks(from: transcript, dual: dual),
                width: textWidth, metrics: metrics, dual: dual,
                budget: CGFloat(model.captionLines) * metrics.lineHeight,
                same: { a, b in a.map(transcript.canonical) == b.map(transcript.canonical) })

            ZStack(alignment: .bottomLeading) {
                if !model.hasKey || rows.isEmpty {
                    CaptionPlaceholder(metrics: metrics)
                        .transition(.blurReplace)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            CaptionRowView(row: row, metrics: metrics, gutter: gutter)
                                .transition(.asymmetric(
                                    insertion: .offset(y: row.height * 0.6).combined(with: .opacity),
                                    removal: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .animation(.smooth(duration: 0.34), value: rows.map(\.id))
                    .animation(.smooth(duration: 0.25), value: gutter)
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
            .clipped()
        }
        .contentShape(.rect)
        .gesture(WindowDragGesture())
        .contextMenu { CaptionMenu() }
    }
}

struct CaptionRowView: View {
    @Environment(AppModel.self) private var model
    let row: CaptionRow
    let metrics: CaptionMetrics
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: gutter > 0 ? metrics.gutterSpacing : 0) {
            if gutter > 0 {
                Group {
                    if row.showsLabel, let speaker = row.speaker {
                        Button {
                            NSApp.activate()
                            model.renaming = RenameRequest(session: model.transcript.id, id: model.transcript.canonical(speaker), place: .caption)
                        } label: {
                            Text(model.speakerName(speaker))
                                .font(.system(size: metrics.labelFontSize, weight: .semibold))
                                .foregroundStyle(model.speakerColor(speaker))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .contentTransition(.interpolate)
                        }
                        .buttonStyle(.plain)
                        .help(tr("Rename speaker"))
                        .transition(.opacity)
                    } else {
                        Text(verbatim: " ").font(.system(size: metrics.labelFontSize))
                    }
                }
                .frame(width: gutter, alignment: .trailing)
            }
            text
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: row.height, alignment: .center)
    }

    private var text: Text {
        let size = row.isOriginal ? metrics.originalFontSize : metrics.fontSize
        let solid = Text(row.solid).foregroundStyle(row.isOriginal ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        let faint = Text(row.faint).foregroundStyle(.tertiary)
        return Text("\(solid)\(faint)")
            .font(.system(size: size, weight: row.isOriginal ? .regular : .medium))
    }
}

struct CaptionPlaceholder: View {
    @Environment(AppModel.self) private var model
    let metrics: CaptionMetrics

    var body: some View {
        HStack(spacing: 12) {
            if !model.hasKey {
                Image(systemName: "key.horizontal")
                    .foregroundStyle(.secondary)
                Text(tr("Add your Soniox API key to start."))
                    .foregroundStyle(.secondary)
                Button(tr("Open Settings…")) { model.openSettings() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } else {
                switch model.status {
                case .idle:
                    Button { model.start() } label: {
                        Label(tr("Start Listening"), systemImage: "waveform")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                    KeyCaps(keys: GlobalShortcut.newSession.keys, size: 11)
                    Text(tr("from any app")).foregroundStyle(.tertiary)
                case .error(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).foregroundStyle(.secondary).lineLimit(2)
                    Button(tr("Try Again")) { model.start() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                default:
                    ListeningText(label: model.status.label)
                }
            }
        }
        .font(.system(size: min(metrics.fontSize * 0.7, 17), weight: .medium))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 8)
    }
}

struct ListeningText: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            PhaseAnimator([0.3, 1.0]) { phase in
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .opacity(phase)
            } animation: { _ in .easeInOut(duration: 0.9) }
            Text(label).foregroundStyle(.secondary)
        }
    }
}

/// A small status light in the corner, so you can tell it’s live without hovering.
struct LiveDot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let color: Color? = switch model.status {
        case .live: .red
        case .connecting, .reconnecting: .orange
        case .paused: .secondary
        default: nil
        }
        if let color {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .opacity(model.status == .live ? Double(0.55 + 0.45 * model.level) : 0.8)
                .animation(.smooth(duration: 0.15), value: model.level)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

struct CaptionToolbar: View {
    @Environment(AppModel.self) private var model
    let namespace: Namespace.ID
    @Binding var languagesShown: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button { model.toggleListening() } label: {
                HStack(spacing: 7) {
                    Image(systemName: model.isListening ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                    if model.isListening {
                        LevelBars(level: model.level, active: model.status == .live, color: .white)
                    }
                }
                .frame(minWidth: 20)
                .padding(.horizontal, 7)
                .frame(height: 34)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(model.isListening ? .red : .accentColor).interactive(), in: .capsule)
            .glassEffectID("play", in: namespace)
            .help(model.isListening ? tr("Pause") : tr("Start Listening"))

            HStack(spacing: 2) {
                Button { languagesShown.toggle() } label: {
                    Text(model.languageSummary)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(.capsule)
                }
                .buttonStyle(ToolbarHoverStyle())
                .popover(isPresented: $languagesShown, arrowEdge: .top) { LanguagePicker().environment(model) }

                Menu {
                    CaptionAppearanceMenu()
                } label: {
                    Image(systemName: "textformat.size")
                        .environment(\.locale, Locale(identifier: "en"))
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(ToolbarHoverStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("Caption appearance"))

                toolbarButton("lock", tr("Lock captions (click-through)") + "  ⌃⌥L") { model.lock(true) }
                toolbarButton("gearshape", tr("Settings…")) { model.openSettings() }
                toolbarButton("eye.slash", tr("Hide Captions") + "  ⌃⌥C") { model.setCaptions(false) }
                toolbarButton("rectangle.expand.vertical", tr("Open transcript") + "  ⌃⌥T") {
                    model.openTranscript()
                }
            }
            .padding(.horizontal, 2)
            .frame(height: 34)
            .glassEffect(.regular, in: .capsule)
            .glassEffectID("tools", in: namespace)

            SourceSwitch(height: 34)
                .glassEffect(.regular, in: .capsule)
                .glassEffectID("source", in: namespace)
        }
        .font(.system(size: 13, weight: .semibold))
    }

    private func toolbarButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(ToolbarHoverStyle())
        .help(help)
    }
}

/// Plain icon button that lights up under the pointer, for controls sitting on glass.
struct ToolbarHoverStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.smooth(duration: 0.15), value: hovering)
            .animation(.smooth(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

struct CaptionAppearanceMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Button(tr("Bigger Text")) { model.adjustFontSize(1, captions: true) }
        Button(tr("Smaller Text")) { model.adjustFontSize(-1, captions: true) }
        Divider()
        Picker(tr("Lines"), selection: $model.captionLines) {
            ForEach(AppModel.captionLineRange, id: \.self) { Text(verbatim: "\($0)").tag($0) }
        }
        Toggle(tr("Show Original"), isOn: $model.captionShowsOriginal)
        Picker(tr("Style"), selection: $model.captionStyle) {
            ForEach(CaptionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle(tr("Keep on Top"), isOn: $model.captionPinned)
    }
}

struct CaptionMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(model.isListening ? tr("Pause") : tr("Start Listening")) { model.toggleListening() }
        SourcePicker()
        Divider()
        CaptionAppearanceMenu()
        Divider()
        Button(tr("Lock Captions")) { model.lock(true) }
        Button(tr("Show Transcript")) { model.openTranscript() }
        Button(tr("Hide Captions")) { model.setCaptions(false) }
    }
}

/// Invisible edge strips: sides change width, top and bottom snap to whole lines.
struct ResizeHandles: View {
    let metrics: CaptionMetrics

    var body: some View {
        ZStack {
            handle(.leading).frame(width: 7).frame(maxWidth: .infinity, alignment: .leading)
            handle(.trailing).frame(width: 7).frame(maxWidth: .infinity, alignment: .trailing)
            handle(.top).frame(height: 6).padding(.horizontal, 24).frame(maxHeight: .infinity, alignment: .top)
            handle(.bottom).frame(height: 6).padding(.horizontal, 24).frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func handle(_ edge: Edge) -> some View {
        let position: FrameResizePosition = switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
        return Color.clear
            .contentShape(.rect)
            .pointerStyle(.frameResize(position: position))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in CaptionPanelController.current?.drag(edge) }
                .onEnded { _ in CaptionPanelController.current?.endDrag() })
    }
}


/// Appears over a locked caption while the pointer is on it.
struct UnlockPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { withAnimation(.smooth) { model.lock(false) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "lock.open.fill")
                Text(tr("Unlock"))
                KeyCaps(keys: GlobalShortcut.lock.keys, size: 10)
            }
            .font(.callout.weight(.semibold))
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 32)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(2)
        .fixedSize()
    }
}
