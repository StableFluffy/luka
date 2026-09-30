import AppKit
import LukaCore

/// `--snapshot <dir>`: periodically writes each window to PNG and the transcript to text.
/// For checking layout on machines where screen capture isn't allowed.
@MainActor
enum Snapshot {
    static func startIfRequested(model: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.indices.contains(i + 1) else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                tick += 1
                write(model: model, to: dir, tick: tick)
            }
        }
    }

    private static func write(model: AppModel, to dir: URL, tick: Int) {
        for (n, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView, view.bounds.width > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window is CaptionPanel ? "caption" : "window\(n)"
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name)-\(tick).png"))
        }
        var text = "status=\(model.status) level=\(model.level)\n"
        for line in model.transcript.lines {
            text += "[\(model.speakerName(line.speaker))|\(line.language ?? "-")] \(line.original)\n    → \(line.translation) {pending: \(line.pendingOriginal)}\n"
        }
        if let p = model.transcript.provisional { text += "(live \(model.speakerName(p.speaker))) \(p.text)\n" }
        try? text.write(to: dir.appendingPathComponent("transcript-\(tick).txt"), atomically: true, encoding: .utf8)
    }
}
