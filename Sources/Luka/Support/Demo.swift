import AppKit
import SwiftUI

/// `--demo`: stages clean screenshots. A gradient backdrop fills the screen behind Luka's
/// windows, speakers get sample names, and the windows are placed in a fixed layout.
/// Pair with `--sessions-dir` so real sessions stay out of frame.
@MainActor
enum Demo {
    static let names = ["Alex", "Mina", "Jun", "Sam"]
    private static var backdrop: NSWindow?

    static func startIfRequested(model: AppModel) {
        guard ProcessInfo.processInfo.arguments.contains("--demo"), let screen = NSScreen.main else { return }
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Above ordinary windows (a background launch can't take focus), below Luka's floating ones.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces]
        window.contentView = NSHostingView(rootView: Backdrop())
        window.orderFront(nil)
        backdrop = window
        model.transcript.title = "Launch sync"

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                for speaker in model.transcript.visibleSpeakers where speaker.name.isEmpty && speaker.ordinal <= names.count {
                    model.transcript.rename(speaker.id, to: names[speaker.ordinal - 1])
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.openTranscript() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { layout(screen: screen) }
    }

    private static func layout(screen: NSScreen) {
        let area = screen.visibleFrame
        let transcript = NSRect(x: area.midX - 560, y: area.midY - 250, width: 1120, height: 620)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("transcript") == true }) {
            window.level = .floating
            window.setFrame(transcript, display: true)
        }
        if let captions = CaptionPanelController.current {
            captions.frame = NSRect(x: area.midX - 470, y: transcript.minY - 190, width: 940, height: captions.frame.height)
        }
        NSApp.activate()
    }
}

private struct Backdrop: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.62, 0.42], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1],
        ], colors: [
            Color(red: 0.08, green: 0.08, blue: 0.10), Color(red: 0.16, green: 0.15, blue: 0.19), Color(red: 0.10, green: 0.10, blue: 0.12),
            Color(red: 0.20, green: 0.19, blue: 0.23), Color(red: 0.52, green: 0.30, blue: 0.22), Color(red: 0.18, green: 0.17, blue: 0.21),
            Color(red: 0.06, green: 0.06, blue: 0.07), Color(red: 0.14, green: 0.13, blue: 0.16), Color(red: 0.07, green: 0.07, blue: 0.08),
        ])
        .ignoresSafeArea()
    }
}
