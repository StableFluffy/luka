import LukaCore
import SwiftUI

/// An ordinary window of large captions, for sharing in a video call.
/// The caption strip is a floating panel that call apps don't offer as a shareable window.
struct PresenterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The caption strip's layout: as many recent rows as fit, newest at the bottom,
        // speaker names in a gutter and repeated on the top row so nobody goes unnamed.
        GeometryReader { geo in
            let metrics = CaptionMetrics(fontSize: model.presenterFontSize)
            let transcript = model.transcript
            let names = transcript.visibleSpeakers.map { model.speakerName($0.id) }
            let gutter = names.isEmpty ? 0 : CaptionLayout.labelWidth(names, metrics: metrics, limit: geo.size.width * 0.26)
            let padding = metrics.horizontalPadding * 1.5
            let textWidth = geo.size.width - padding * 2 - (gutter > 0 ? gutter + metrics.gutterSpacing : 0) - 4
            // Everyone on the call reads it in their own language, so the original always shows.
            let dual = true
            let rows = CaptionLayout.rows(
                CaptionLayout.blocks(from: transcript, dual: dual, limit: 24),
                width: textWidth, metrics: metrics, dual: dual,
                budget: geo.size.height - metrics.verticalPadding * 3,
                originalBelow: true,
                same: { a, b in a.map(transcript.canonical) == b.map(transcript.canonical) })

            ZStack(alignment: .bottomLeading) {
                if rows.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "captions.bubble").font(.system(size: 40))
                        Text(model.isListening ? tr("Listening…") : tr("Captions appear here when Luka is listening."))
                            .font(.system(size: 20, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    // Names here are for viewers; renaming happens in the caption strip and transcript.
                    .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, padding)
            .padding(.vertical, metrics.verticalPadding * 1.5)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
            .clipped()
        }
        .frame(minWidth: 480, minHeight: 270)
        // Fixed dark and high contrast, so it reads the same for everyone on the call.
        .environment(\.colorScheme, .dark)
        .background(.black)
        .containerBackground(.black, for: .window)
        .navigationTitle(tr("Shared Captions"))
        .onAppear { model.presenterVisible = true }
        .onDisappear { model.presenterVisible = false }
    }
}
