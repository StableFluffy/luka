import Foundation
import LukaCore

enum AudioSource: String, CaseIterable, Codable, Sendable {
    case system, microphone, both
}

/// Owns the capture devices, mixes them when both are on, and hands out 100 ms s16le chunks.
final class AudioPipeline: @unchecked Sendable {
    private static let chunk = 1_600
    /// When one source stalls this long, stop waiting for it and pad with silence.
    private static let maxSkew = 4_800

    private let lock = NSLock()
    private var system: [Int16] = []
    private var mic: [Int16] = []
    private var source: AudioSource = .system
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var feed: FileFeed?
    private var startedAt = Date.distantPast
    private var heardSound = false

    /// Called on a capture thread.
    var onChunk: @Sendable (Data, Float) -> Void = { _, _ in }

    var isRunning: Bool { lock.withLock { systemCapture != nil || micCapture != nil || feed != nil } }

    func start(_ source: AudioSource, feedFile: URL?) async throws {
        stop()
        lock.withLock {
            self.source = source
            system.removeAll()
            mic.removeAll()
            startedAt = .now
            heardSound = false
        }
        AudioLog.write("capture start: \(source.rawValue)")
        if let feedFile {
            let feed = try FileFeed(url: feedFile) { [weak self] in self?.push($0, fromMic: false) }
            lock.withLock { self.feed = feed }
            feed.start()
            return
        }
        if source != .system {
            guard await MicrophoneCapture.requestAccess() else { throw CaptureError.microphoneDenied }
            let capture = MicrophoneCapture { [weak self] in self?.push($0, fromMic: true) }
            try capture.start()
            lock.withLock { micCapture = capture }
        }
        if source != .microphone {
            let capture = SystemAudioCapture { [weak self] in self?.push($0, fromMic: false) }
            do {
                try capture.start()
            } catch {
                stop()
                throw error
            }
            lock.withLock { systemCapture = capture }
        }
    }

    func stop() {
        let (s, m, f) = lock.withLock { () -> (SystemAudioCapture?, MicrophoneCapture?, FileFeed?) in
            defer { systemCapture = nil; micCapture = nil; feed = nil }
            return (systemCapture, micCapture, feed)
        }
        s?.stop()
        m?.stop()
        f?.stop()
    }

    private func push(_ samples: [Int16], fromMic: Bool) {
        var out: [[Int16]] = []
        lock.withLock {
            if source == .both {
                if fromMic { mic += samples } else { system += samples }
                while true {
                    let ready = min(mic.count, system.count)
                    let stalled = max(mic.count, system.count) >= Self.maxSkew
                    guard ready >= Self.chunk || stalled else { break }
                    let n = Self.chunk
                    var mixed = [Int16](repeating: 0, count: n)
                    for i in 0..<n {
                        let a = i < mic.count ? Int32(mic[i]) : 0
                        let b = i < system.count ? Int32(system[i]) : 0
                        mixed[i] = Int16(clamping: a + b)
                    }
                    mic.removeFirst(min(n, mic.count))
                    system.removeFirst(min(n, system.count))
                    out.append(mixed)
                }
            } else {
                system += samples
                while system.count >= Self.chunk {
                    out.append(Array(system.prefix(Self.chunk)))
                    system.removeFirst(Self.chunk)
                }
            }
        }
        for chunk in out {
            let level = Self.level(chunk)
            if level > 0.2, lock.withLock({ !heardSound }) {
                lock.withLock { heardSound = true }
                AudioLog.write(String(format: "first sound after %.2f s", Date.now.timeIntervalSince(lock.withLock { startedAt })))
            }
            onChunk(Self.encode(chunk), level)
        }
    }

    static func silence(milliseconds: Int) -> Data {
        Data(count: 16 * milliseconds * 2)
    }

    private static func encode(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// 0…1, roughly perceptual: −60 dBFS maps to 0.
    private static func level(_ samples: [Int16]) -> Float {
        var sum: Float = 0
        for s in samples { let f = Float(s) / 32768; sum += f * f }
        let rms = (sum / Float(max(samples.count, 1))).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 60) / 60))
    }
}

/// Streams a 16 kHz mono s16le file in real time. Used for demos and testing without permissions.
final class FileFeed: @unchecked Sendable {
    private let samples: [Int16]
    private let onSamples: @Sendable ([Int16]) -> Void
    private var timer: DispatchSourceTimer?
    private var offset = 0

    init(url: URL, onSamples: @escaping @Sendable ([Int16]) -> Void) throws {
        var data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "wav", data.count > 44 { data = data.dropFirst(44) }
        samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        self.onSamples = onSamples
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let end = min(self.offset + 1_600, self.samples.count)
            let slice = end > self.offset ? Array(self.samples[self.offset..<end]) : [Int16](repeating: 0, count: 1_600)
            self.offset = end
            self.onSamples(slice)
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
