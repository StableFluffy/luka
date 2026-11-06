import AVFoundation
import CoreAudio

/// Records the chosen input device, or the system default, through a Core Audio IOProc.
///
/// AVAudioEngine can't be pointed at another input reliably: its input node keeps the default
/// device's format, so a Continuity (iPhone) microphone at 48 kHz behind a 16 kHz Bluetooth
/// default delivers nothing and the engine stops. An IOProc on the device itself has no such
/// coupling. A chosen device that vanishes gets a few seconds to come back before Luka falls
/// back to the default input, and Luka returns to it when it reappears.
final class MicrophoneCapture: @unchecked Sendable {
    /// How long a chosen device may be missing before falling back to the default input.
    private static let fallbackDelay: TimeInterval = 4

    private let onSamples: @Sendable ([Int16]) -> Void
    /// Core Audio UID of the device to record from; nil follows the system default input.
    private let deviceUID: String?
    private let control = DispatchQueue(label: "luka.microphone.control")
    private let io = DispatchQueue(label: "luka.microphone.io", qos: .userInitiated)
    private let lock = NSLock()

    private var running = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var lastCallback = Date.distantPast
    private var builtAt = Date.distantPast
    private var gotCallback = false
    private var watchdog: DispatchSourceTimer?
    private var rebuildWork: DispatchWorkItem?
    private var fallbackWork: DispatchWorkItem?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    private var devicesAddress = MicrophoneCapture.address(kAudioHardwarePropertyDevices)
    private var defaultInputAddress = MicrophoneCapture.address(kAudioHardwarePropertyDefaultInputDevice)
    private var aliveAddress = MicrophoneCapture.address(kAudioDevicePropertyDeviceIsAlive)
    private var formatAddress = MicrophoneCapture.address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)

    init(deviceUID: String?, onSamples: @escaping @Sendable ([Int16]) -> Void) {
        self.deviceUID = deviceUID
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
        try control.sync {
            running = true
            var target = deviceUID == nil ? Self.defaultInput() : chosenDevice()
            if let deviceUID, target == nil {
                AudioLog.write("microphone \(deviceUID) not found: using default input")
                target = Self.defaultInput()
            }
            guard let target else {
                running = false
                throw CaptureError.noMicrophone
            }
            do {
                try build(target)
            } catch {
                running = false
                teardown()
                throw error
            }
            // A chosen device is watched for coming back; the default is followed when it changes.
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.hardwareChanged() }
            systemListener = listener
            if deviceUID != nil {
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, control, listener)
            } else {
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, control, listener)
            }
            startWatchdog()
        }
    }

    func stop() {
        control.sync {
            running = false
            watchdog?.cancel()
            watchdog = nil
            rebuildWork?.cancel()
            fallbackWork?.cancel()
            fallbackWork = nil
            if let systemListener {
                let system = AudioObjectID(kAudioObjectSystemObject)
                if deviceUID != nil {
                    AudioObjectRemovePropertyListenerBlock(system, &devicesAddress, control, systemListener)
                } else {
                    AudioObjectRemovePropertyListenerBlock(system, &defaultInputAddress, control, systemListener)
                }
            }
            systemListener = nil
            teardown()
        }
    }

    // MARK: Build / teardown (control queue)

    private func build(_ target: AudioObjectID) throws {
        teardown()
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(target, &formatAddress, 0, nil, &size, &asbd))
        // The IOProc's first buffer is the device's first input stream, which is interleaved.
        asbd.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
        guard asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.noMicrophone }

        let converter = PCMConverter()
        let onSamples = onSamples
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, target, io) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let first = self.lock.withLock { () -> Bool in
                self.lastCallback = .now
                defer { self.gotCallback = true }
                return !self.gotCallback
            }
            if first { AudioLog.write(String(format: "microphone first callback after %.2f s", Date.now.timeIntervalSince(self.builtAt))) }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let stream = buffers.first, stream.mData != nil else { return }
            var single = AudioBufferList(mNumberBuffers: 1, mBuffers: stream)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &single, deallocator: nil) else { return }
            let samples = converter.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        })
        device = target
        procID = proc

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild("device changed") }
        deviceListener = listener
        AudioObjectAddPropertyListenerBlock(target, &aliveAddress, control, listener)
        AudioObjectAddPropertyListenerBlock(target, &formatAddress, control, listener)

        lock.withLock {
            lastCallback = .now
            builtAt = .now
            gotCallback = false
        }
        try check(AudioDeviceStart(target, proc))
        AudioLog.write("microphone started: \(Self.name(target)), \(Int(asbd.mSampleRate)) Hz × \(asbd.mChannelsPerFrame)")
    }

    private func teardown() {
        guard device != kAudioObjectUnknown else { return }
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(device, &aliveAddress, control, deviceListener)
            AudioObjectRemovePropertyListenerBlock(device, &formatAddress, control, deviceListener)
        }
        deviceListener = nil
        if let procID {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        procID = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            AudioLog.write("microphone error \(status)")
            throw CaptureError.noMicrophone
        }
    }

    // MARK: Following the device

    private func chosenDevice() -> AudioObjectID? {
        deviceUID.flatMap(InputDevices.device(uid:))
    }

    /// The device list changed (chosen device) or the default input changed (no choice).
    private func hardwareChanged() {
        guard running else { return }
        if deviceUID == nil {
            if Self.defaultInput() != device { scheduleRebuild("default input changed") }
        } else if let chosen = chosenDevice(), chosen != device {
            scheduleRebuild("chosen microphone is available")
        } else if chosenDevice() == nil, device != kAudioObjectUnknown, !Self.isAlive(device) {
            scheduleRebuild("microphone disappeared")
        }
    }

    /// Changes come in bursts while a device reconnects, so wait for them to settle.
    private func scheduleRebuild(_ reason: String) {
        guard running else { return }
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(reason) }
        rebuildWork = work
        control.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func rebuild(_ reason: String) {
        guard running else { return }
        AudioLog.write("rebuilding microphone: \(reason)")
        if deviceUID == nil {
            attach(to: Self.defaultInput())
            return
        }
        if let chosen = chosenDevice() {
            fallbackWork?.cancel()
            fallbackWork = nil
            attach(to: chosen)
            return
        }
        // Usually it comes back in a moment; don't jump to the default input before then.
        teardown()
        guard fallbackWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.fallbackWork = nil
            guard self.device == kAudioObjectUnknown else { return }
            AudioLog.write("microphone \(self.deviceUID ?? "-") still missing: using default input")
            self.attach(to: Self.defaultInput())
        }
        fallbackWork = work
        control.asyncAfter(deadline: .now() + Self.fallbackDelay, execute: work)
    }

    private func attach(to target: AudioObjectID?) {
        guard let target else {
            teardown()
            AudioLog.write("no input device")
            return
        }
        do {
            try build(target)
        } catch {
            teardown()
            AudioLog.write("microphone rebuild failed: \(error.localizedDescription)")
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.running, self.device != kAudioObjectUnknown else { return }
            let (last, started) = self.lock.withLock { (self.lastCallback, self.gotCallback) }
            let silentFor = Date.now.timeIntervalSince(last)
            // A Continuity microphone takes a few seconds to wake before its first callback.
            if silentFor > (started ? 2 : 8) { self.scheduleRebuild("no callbacks for \(Int(silentFor)) s") }
        }
        timer.resume()
        watchdog = timer
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInput() -> AudioObjectID? {
        var address = MicrophoneCapture.address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    private static func isAlive(_ device: AudioObjectID) -> Bool {
        var address = MicrophoneCapture.address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    private static func name(_ device: AudioObjectID) -> String {
        InputDevices.list().first { $0.id == device }?.name ?? "device \(device)"
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
