import LukaCore
import SwiftUI

struct TranscriptWindow: View {
    @Environment(AppModel.self) private var model
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SessionSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
        } detail: {
            if let t = model.selectedTranscript {
                SessionView(transcript: t)
                    .id(t.id)
                    .environment(\.session, t)
            } else {
                ContentUnavailableView(tr("No Session"), systemImage: "text.bubble")
            }
        }
        .frame(minWidth: 560, minHeight: 360)
        .background(WindowConfigurator(pinned: model.transcriptPinned))
        .onAppear { model.transcriptVisible = true }
        .onDisappear { model.transcriptVisible = false }
    }
}

// MARK: - Sidebar

struct SessionSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renamingID: UUID?
    @State private var pendingDelete: UUID?

    struct Row: Identifiable {
        let id: UUID
        let title: String
        let createdAt: Date
        let preview: String
        let isLive: Bool
    }

    private var rows: [Row] {
        let live = model.transcript
        var rows = model.store.summaries.filter { $0.id != live.id }.map {
            Row(id: $0.id, title: $0.title.isEmpty ? AppModel.defaultTitle($0.createdAt) : $0.title,
                createdAt: $0.createdAt, preview: $0.preview, isLive: false)
        }
        let preview = live.lines.first.map(\.primary) ?? (model.isListening ? tr("Listening…") : tr("Nothing yet"))
        rows.append(Row(id: live.id, title: model.title(live), createdAt: live.createdAt, preview: preview, isLive: true))
        return rows.sorted { $0.createdAt > $1.createdAt }
    }

    private var sections: [(title: String, rows: [Row])] {
        let calendar = Calendar.current
        var result: [(String, [Row])] = []
        for row in rows {
            let title: String
            if calendar.isDateInToday(row.createdAt) { title = tr("Today") }
            else if calendar.isDateInYesterday(row.createdAt) { title = tr("Yesterday") }
            else { title = row.createdAt.formatted(Date.FormatStyle(date: .long).locale(Localizer.shared.locale)) }
            if result.last?.0 == title { result[result.count - 1].1.append(row) } else { result.append((title, [row])) }
        }
        return result
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedID) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        SessionRow(row: row, renaming: renamingID == row.id) { renamingID = nil }
                            .tag(row.id)
                            .contextMenu { menu(for: row) }
                    }
                }
            }
        }
        .animation(.smooth, value: rows.map(\.id))
        .onDeleteCommand { pendingDelete = model.selectedID }
        .confirmationDialog(tr("Delete this session?"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(tr("Delete"), role: .destructive) {
                if let id = pendingDelete { withAnimation(.smooth) { model.deleteSession(id) } }
                pendingDelete = nil
            }
        } message: {
            Text(tr("The transcript will be removed from this Mac."))
        }
        .toolbar {
            ToolbarItem {
                Button { withAnimation(.smooth) { model.newSession() } } label: {
                    Label(tr("New Session"), systemImage: "plus")
                }
                .help(tr("New Session") + "  ⌘N")
            }
        }
    }

    @ViewBuilder private func menu(for row: Row) -> some View {
        Button(tr("Rename…")) { renamingID = row.id }
        Button(tr("Copy Transcript")) { if let t = transcript(row.id) { model.copy(t) } }
        Button(tr("Export…")) { if let t = transcript(row.id) { model.exportTranscript(t) } }
        Divider()
        Button(tr("Delete…"), role: .destructive) { pendingDelete = row.id }
    }

    private func transcript(_ id: UUID) -> Transcript? {
        id == model.transcript.id ? model.transcript : model.store.transcript(id)
    }
}

private struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let row: SessionSidebar.Row
    let renaming: Bool
    let done: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if renaming {
                    TextField(tr("Title"), text: $draft)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(commit)
                        .onAppear { draft = row.title; focused = true }
                        .onChange(of: focused) { if !focused { commit() } }
                } else {
                    Text(row.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if row.isLive && model.isListening {
                    LevelBars(level: model.level, active: model.status == .live, color: .red)
                        .scaleEffect(0.8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            Text(row.preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
        .animation(.smooth, value: model.isListening)
    }

    private func commit() {
        guard renaming else { return }
        let t = row.id == model.transcript.id ? model.transcript : model.store.transcript(row.id)
        if let t {
            t.title = draft == AppModel.defaultTitle(t.createdAt) ? "" : draft.trimmingCharacters(in: .whitespaces)
            model.store.save(t)
        }
        done()
    }
}

// MARK: - Session

struct SessionView: View {
    @Environment(AppModel.self) private var model
    let transcript: Transcript
    @State private var position: ScrollPosition
    @State private var following = true
    @State private var speakersShown = false
    @State private var editing = false
    @State private var confirmingDelete = false

    init(transcript: Transcript) {
        self.transcript = transcript
        _position = State(initialValue: ScrollPosition(edge: .bottom))
    }

    private var isLive: Bool { model.isLive(transcript) }
    private var isStreaming: Bool { isLive && model.status != .idle && !isError }
    private var isError: Bool { if case .error = model.status { true } else { false } }

    var body: some View {
        content
            .animation(.smooth, value: transcript.isEmpty)
            .safeAreaInset(edge: .bottom) { bottomBar }
            .overlay(alignment: .top) { noticeView }
            .toolbar { toolbarContent }
            .navigationTitle(model.title(transcript))
            .toolbar(removing: .title)
            .onChange(of: isStreaming) { if isStreaming { editing = false } }
            .confirmationDialog(tr("Delete this session?"), isPresented: $confirmingDelete) {
                Button(tr("Delete"), role: .destructive) { withAnimation(.smooth) { model.deleteSession(transcript.id) } }
            } message: {
                Text(tr("The transcript will be removed from this Mac."))
            }
            .onDisappear { if !isLive { model.store.save(transcript) } }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { model.title(transcript) },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                transcript.title = trimmed == AppModel.defaultTitle(transcript.createdAt) ? "" : trimmed
                model.store.save(transcript)
            })
    }

    @ViewBuilder private var content: some View {
        ZStack {
            if transcript.isEmpty {
                TranscriptEmptyState(isLive: isLive)
                    .transition(.blurReplace)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        let joins = provisionalJoinsLastTurn
                        let lastTurn = transcript.turns.last?.id
                        ForEach(transcript.turns) { turn in
                            TurnView(transcript: transcript, turn: turn, editing: editing,
                                     live: joins && turn.id == lastTurn ? transcript.provisional : nil)
                        }
                        if let p = transcript.provisional, !joins {
                            TurnView(transcript: transcript, turn: Turn(speaker: p.speaker.map(transcript.canonical), lines: []),
                                     editing: false, live: p)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 16)
                    .padding(.bottom, 96)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition($position)
                .defaultScrollAnchor(isLive ? .bottom : .top)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
                } action: { _, atBottom in
                    following = atBottom
                }
                .onChange(of: transcript.lines.last?.translation.count) { scrollIfFollowing() }
                .onChange(of: transcript.lines.count) { scrollIfFollowing() }
                .onChange(of: transcript.provisional?.text) { scrollIfFollowing() }
                .transition(.opacity)
            }
        }
    }

    private var bottomBar: some View {
        ZStack(alignment: .top) {
            if isLive {
                ControlBar(transcript: transcript)
            } else if model.isListening {
                Button { withAnimation(.smooth) { model.selectedID = model.transcript.id } } label: {
                    Label(tr("Back to Live Session"), systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 30)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            } else {
                ArchivedBar(transcript: transcript)
            }
            if isLive && !following && !transcript.isEmpty {
                Button {
                    withAnimation(.smooth) { position.scrollTo(edge: .bottom) }
                } label: {
                    Label(tr("Jump to Live"), systemImage: "arrow.down")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.glass)
                .offset(y: -44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: following)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var noticeView: some View {
        if let notice = model.notice {
            Text(notice)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            EditableTitle(title: titleBinding, placeholder: AppModel.defaultTitle(transcript.createdAt))
        }
        .sharedBackgroundVisibility(.hidden)
        if isLive && model.status != .idle {
            ToolbarItem(placement: .navigation) {
                StatusPill()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { speakersShown.toggle() } label: {
                Label(tr("Speakers"), systemImage: "person.2")
            }
            .help(tr("Speakers"))
            .popover(isPresented: $speakersShown, arrowEdge: .bottom) {
                SpeakersList().environment(model).environment(\.session, transcript)
            }
            Toggle(isOn: $model.transcriptShowsOriginal.animation(.smooth)) {
                Label(tr("Show Original"), systemImage: "character.bubble")
            }
            .help(tr("Show Original"))
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $editing.animation(.smooth)) {
                Label(tr("Edit"), systemImage: "pencil")
            }
            .help(isStreaming ? tr("Finish the session to edit") : tr("Edit transcript"))
            .disabled(isStreaming || transcript.lines.isEmpty)
            Button { model.copy(transcript) } label: {
                Label(tr("Copy Transcript"), systemImage: "doc.on.doc")
            }
            .help(tr("Copy Transcript") + "  ⇧⌘C")
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(transcript.lines.isEmpty)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.captionsVisible) {
                Label(tr("Captions"), systemImage: "captions.bubble")
            }
            .help(tr("Show Captions") + "  ⌘1")
            Menu {
                Toggle(tr("Keep on Top"), isOn: $model.transcriptPinned)
                Button(tr("Export Transcript…")) { model.exportTranscript(transcript) }
                    .disabled(transcript.lines.isEmpty)
                Divider()
                Button(tr("Delete Session…"), role: .destructive) { confirmingDelete = true }
                    .disabled(transcript.lines.isEmpty && isLive)
            } label: {
                Label(tr("More"), systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            Button { model.openSettings() } label: {
                Label(tr("Settings…"), systemImage: "gearshape")
            }
            .help(tr("Settings…") + "  ⌘,")
        }
    }

    private var provisionalJoinsLastTurn: Bool {
        guard let p = transcript.provisional, let last = transcript.turns.last else { return false }
        return p.speaker.map(transcript.canonical) == last.speaker || p.speaker == nil
    }

    private func scrollIfFollowing() {
        guard isLive, following else { return }
        withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
    }
}

struct TurnView: View {
    @Environment(AppModel.self) private var model
    let transcript: Transcript
    let turn: Turn
    let editing: Bool
    /// Words still being recognized, when they belong to this turn.
    let live: Provisional?

    var body: some View {
        let size = model.transcriptFontSize
        let showOriginal = model.transcriptShowsOriginal
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if turn.speaker != nil {
                    SpeakerChip(id: turn.speaker, turn: turn.id, font: .system(size: max(11, size - 2), weight: .semibold))
                        .popover(isPresented: renameBinding, arrowEdge: .trailing) {
                            if let s = turn.speaker { SpeakerEditor(id: s).environment(model).environment(\.session, transcript) }
                        }
                }
                if let start = turn.lines.first?.startedAt {
                    Text(verbatim: Self.time.string(from: start))
                        .font(.system(size: max(10, size - 4)).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                let liveJoinsLine = turn.lines.last.map { $0.isOpen && $0.id == transcript.lines.last?.id } ?? false
                ForEach(turn.lines) { line in
                    if editing {
                        EditableLine(transcript: transcript, line: line, showOriginal: showOriginal, size: size)
                            .transition(.opacity)
                    } else {
                        LineView(line: line, showOriginal: showOriginal, size: size,
                                 provisional: liveJoinsLine && line.id == turn.lines.last?.id ? live : nil)
                    }
                }
                if let p = live, !liveJoinsLine {
                    Text(p.text)
                        .font(.system(size: size))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 13)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var renameBinding: Binding<Bool> {
        Binding(
            get: {
                guard let request = model.renaming, request.session == transcript.id,
                      case .transcript(let target) = request.place,
                      let speaker = turn.speaker, request.id == speaker else { return false }
                if let target { return target == turn.id }
                return transcript.turns.last(where: { $0.speaker == speaker })?.id == turn.id
            },
            set: { if !$0 { model.renaming = nil } })
    }
}

struct LineView: View {
    let line: Line
    let showOriginal: Bool
    let size: Double
    let provisional: Provisional?

    var body: some View {
        let live = provisional?.text ?? ""
        VStack(alignment: .leading, spacing: 3) {
            if line.expectsTranslation {
                let pending = [line.pendingOriginal, live].filter { !$0.isEmpty }.joined(separator: " ")
                if !line.translation.isEmpty || pending.isEmpty {
                    Text(line.translation)
                        .font(.system(size: size))
                        .foregroundStyle(.primary)
                }
                if showOriginal {
                    Text("\(Text(line.original))\(Text(live.isEmpty ? "" : (line.original.isEmpty ? live : " " + live)).foregroundStyle(.tertiary))")
                        .font(.system(size: max(10, size - 2)))
                        .foregroundStyle(.secondary)
                } else if !pending.isEmpty {
                    Text(pending)
                        .font(.system(size: size))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("\(Text(line.original))\(Text(live.isEmpty ? "" : " " + live).foregroundStyle(.tertiary))")
                    .font(.system(size: size))
            }
        }
        .lineSpacing(size * 0.18)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct EditableLine: View {
    let transcript: Transcript
    let line: Line
    let showOriginal: Bool
    let size: Double
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if line.expectsTranslation {
                    field(Binding(get: { line.translation }, set: { [transcript, id = line.id] in transcript.edit(line: id, translation: $0) }), size: size)
                    if showOriginal {
                        field(Binding(get: { line.original }, set: { [transcript, id = line.id] in transcript.edit(line: id, original: $0) }), size: max(10, size - 2), secondary: true)
                    }
                } else {
                    field(Binding(get: { line.original }, set: { [transcript, id = line.id] in transcript.edit(line: id, original: $0) }), size: size)
                }
            }
            Button(role: .destructive) { withAnimation(.smooth) { transcript.delete(line: line.id) } } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help(tr("Delete Line"))
        }
        .padding(6)
        .background(.quaternary.opacity(hovering ? 0.6 : 0.3), in: .rect(cornerRadius: 8))
        .onHover { hovering = $0 }
    }

    private func field(_ text: Binding<String>, size: Double, secondary: Bool = false) -> some View {
        TextField("", text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: size))
            .foregroundStyle(secondary ? .secondary : .primary)
    }
}

/// The session title, edited in place: click it, type, press Return.
struct EditableTitle: View {
    @Binding var title: String
    let placeholder: String
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .focused($focused)
            .fixedSize()
            .frame(minWidth: 120, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(focused ? 0.08 : hovering ? 0.05 : 0)))
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.15), value: hovering)
            .animation(.smooth(duration: 0.15), value: focused)
            .help(tr("Rename…"))
            .onAppear { draft = title }
            .onChange(of: title) { if !focused { draft = title } }
            .onChange(of: focused) { if !focused { commit() } }
            .onSubmit {
                commit()
                focused = false
            }
            .onExitCommand {
                draft = title
                focused = false
            }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { draft = placeholder }
        if draft != title { title = draft }
    }
}

struct StatusPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.status == .live ? Color.red : model.isListening ? .orange : .secondary)
                .frame(width: 7, height: 7)
            Text(model.status.label)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
            if let started = model.startedAt, model.status != .idle {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 60, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .animation(.smooth, value: model.status)
    }
}

struct ControlBar: View {
    @Environment(AppModel.self) private var model
    let transcript: Transcript
    @State private var languagesShown = false
    @Namespace private var glass

    private var startTitle: String {
        if model.isListening { return tr("Pause") }
        if model.status == .paused { return tr("Resume") }
        return transcript.lines.isEmpty ? tr("Start Listening") : tr("Continue")
    }

    var body: some View {
        let streamOpen = model.status != .idle
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { model.toggleListening() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.isListening ? "pause.fill" : "waveform")
                            .contentTransition(.symbolEffect(.replace))
                            .font(.system(size: 15, weight: .semibold))
                        Text(startTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .contentTransition(.interpolate)
                        if model.isListening {
                            LevelBars(level: model.level, active: model.status == .live, color: .white)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(model.isListening ? .red : .accentColor).interactive(), in: .capsule)
                .glassEffectID("listen", in: glass)
                .keyboardShortcut("r", modifiers: .command)

                if streamOpen {
                    Button { withAnimation(.smooth) { model.endSession() } } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("done", in: glass)
                    .help(tr("Finish Session") + "  ⌘.")
                    .keyboardShortcut(".", modifiers: .command)
                }

                Button { languagesShown.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.mode == .transcribe ? "text.quote" : "globe")
                        Text(model.languageSummary).lineLimit(1).fixedSize()
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("languages", in: glass)
                .popover(isPresented: $languagesShown, arrowEdge: .top) { LanguagePicker().environment(model) }

                SourceSwitch()
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectID("source", in: glass)
            }
        }
        .animation(.smooth(duration: 0.3), value: model.isListening)
        .animation(.smooth(duration: 0.3), value: streamOpen)
    }
}

/// Bottom bar for a finished session: pick it back up, or start fresh.
private struct ArchivedBar: View {
    @Environment(AppModel.self) private var model
    let transcript: Transcript

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { model.continueSession(transcript) } label: {
                    Label(tr("Continue"), systemImage: "waveform")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
                Button { withAnimation(.smooth) { model.newSession() } } label: {
                    Label(tr("New Session"), systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
    }
}

struct TranscriptEmptyState: View {
    @Environment(AppModel.self) private var model
    var isLive = true
    @State private var key = ""

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: model.hasKey ? "captions.bubble" : "key.horizontal")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: model.isListening && isLive)
            VStack(spacing: 6) {
                Text(model.hasKey ? (model.isListening && isLive ? tr("Listening…") : tr("Ready when you are")) : tr("Connect Soniox"))
                    .font(.title2.weight(.semibold))
                Text(model.hasKey
                     ? tr("Luka listens to your Mac and writes down every speaker, translated as they talk.")
                     : tr("Paste a Soniox API key to start. It’s stored encrypted on this Mac."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            if !model.hasKey {
                HStack(spacing: 8) {
                    SecureField(tr("API key"), text: $key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .onSubmit(save)
                    Button(tr("Save"), action: save)
                        .buttonStyle(.glassProminent)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Link(tr("Get a key at console.soniox.com"), destination: URL(string: "https://console.soniox.com")!)
                    .font(.callout)
            } else if case .error(let message) = model.status, isLive {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            } else if !(model.isListening && isLive) {
                ShortcutGuide()
                    .padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.smooth) { model.apiKey = trimmed }
    }
}

struct SpeakersList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.session) private var session
    @State private var editing: SpeakerID?

    var body: some View {
        let speakers = (session ?? model.transcript).visibleSpeakers
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("Speakers"))
                .font(.headline)
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 8)
            if speakers.isEmpty {
                Text(tr("Speakers appear here as they talk."))
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(speakers) { speaker in
                            SpeakerRow(speaker: speaker, expanded: editing == speaker.id) {
                                withAnimation(.smooth) { editing = editing == speaker.id ? nil : speaker.id }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 300)
    }
}

private struct SpeakerRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.session) private var session
    let speaker: Speaker
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let t = session ?? model.transcript
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle().fill(SpeakerPalette.color(speaker.colorIndex)).frame(width: 10, height: 10)
                TextField(String(format: tr("Speaker %d"), speaker.ordinal), text: Binding(
                    get: { speaker.name }, set: { t.rename(speaker.id, to: $0) }))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                Button(action: toggle) {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if expanded {
                SpeakerEditor(id: speaker.id)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.quaternary.opacity(expanded ? 0.5 : 0), in: .rect(cornerRadius: 10))
    }
}

/// Reaches the hosting NSWindow for things SwiftUI scenes don't expose.
struct WindowConfigurator: NSViewRepresentable {
    let pinned: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = pinned ? .floating : .normal
            window.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary]
        }
    }
}
