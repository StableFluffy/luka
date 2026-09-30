import AVFoundation

final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter = PCMConverter()
    private let onSamples: @Sendable ([Int16]) -> Void

    init(onSamples: @escaping @Sendable ([Int16]) -> Void) {
        self.onSamples = onSamples
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [converter, onSamples] buffer, _ in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

enum CaptureError: LocalizedError {
    case noMicrophone, microphoneDenied, systemAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noMicrophone: tr("No microphone found.")
        case .microphoneDenied: tr("Microphone access is off. Turn it on in System Settings › Privacy & Security.")
        case .systemAudio(let status): String(format: tr("Couldn’t capture system audio (%d)."), Int(status))
        }
    }
}
