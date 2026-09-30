import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (minus this app) through a Core Audio process tap.
/// Needs only the “System Audio Recording” permission, not Screen Recording.
///
/// The tap's aggregate device is clocked by the built-in output, which never disappears,
/// rather than the default output, which changes whenever AirPods connect or switch between
/// A2DP and HFP. Output-device and tap-format changes, and stalled callbacks, rebuild the tap.
final class SystemAudioCapture: @unchecked Sendable {
    private let onSamples: @Sendable ([Int16]) -> Void
    private let control = DispatchQueue(label: "luka.system-audio.control")
    private let io = DispatchQueue(label: "luka.system-audio.io", qos: .userInitiated)
    private let lock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter = PCMConverter()
    private var lastCallback = Date.distantPast
    private var builtAt = Date.distantPast
    private var gotCallback = false
    private var running = false
    private var watchdog: DispatchSourceTimer?
    private var rebuildWork: DispatchWorkItem?
    private var rebuildPending = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var formatListener: AudioObjectPropertyListenerBlock?

    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private var tapFormatAddress = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    init(onSamples: @escaping @Sendable ([Int16]) -> Void) {
        self.onSamples = onSamples
    }

    func start() throws {
        try control.sync {
            running = true
            try build()
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild("default output changed") }
            outputListener = listener
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, control, listener)
            startWatchdog()
        }
    }

    func stop() {
        control.sync {
            running = false
            watchdog?.cancel()
            watchdog = nil
            rebuildWork?.cancel()
            rebuildPending = false
            if let outputListener {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, control, outputListener)
            }
            outputListener = nil
            teardown()
        }
    }

    // MARK: Build / teardown (control queue)

    private func build() throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Luka"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        try check(AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &tapFormatAddress, 0, nil, &size, &format))
        guard let avFormat = AVAudioFormat(streamDescription: &format) else { throw CaptureError.systemAudio(-1) }

        let clockUID = try Self.clockDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Luka Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        let formatListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild("tap format changed") }
        self.formatListener = formatListener
        AudioObjectAddPropertyListenerBlock(tapID, &tapFormatAddress, control, formatListener)

        let converter = PCMConverter()
        self.converter = converter
        let onSamples = onSamples
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, io) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            let first = self.lock.withLock { () -> Bool in
                self.lastCallback = .now
                defer { self.gotCallback = true }
                return !self.gotCallback
            }
            if first { AudioLog.write(String(format: "first callback after %.2f s", Date.now.timeIntervalSince(self.builtAt))) }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: input, deallocator: nil) else { return }
            let samples = converter.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        })
        lock.withLock {
            lastCallback = .now
            builtAt = .now
            gotCallback = false
        }
        try check(AudioDeviceStart(aggregateID, procID))
        AudioLog.write("system tap started: \(Int(format.mSampleRate)) Hz × \(format.mChannelsPerFrame), clock \(clockUID)")
    }

    private func teardown() {
        if tapID != kAudioObjectUnknown, let formatListener {
            AudioObjectRemovePropertyListenerBlock(tapID, &tapFormatAddress, control, formatListener)
        }
        formatListener = nil
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }

    /// Device switches arrive as bursts of notifications; rebuild once they settle.
    private func scheduleRebuild(_ reason: String) {
        rebuildWork?.cancel()
        rebuildPending = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.rebuildPending = false
            AudioLog.write("rebuilding system tap: \(reason)")
            self.teardown()
            do {
                try self.build()
            } catch {
                AudioLog.write("rebuild failed: \(error.localizedDescription); retrying")
                self.scheduleRebuild("retry")
            }
        }
        rebuildWork = work
        control.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 2, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.running, !self.rebuildPending else { return }
            let silentFor = Date.now.timeIntervalSince(self.lock.withLock { self.lastCallback })
            if silentFor > 2 { self.scheduleRebuild("no callbacks for \(Int(silentFor)) s") }
        }
        timer.resume()
        watchdog = timer
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            teardown()
            throw CaptureError.systemAudio(status)
        }
    }

    // MARK: Devices

    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Built-in output when the Mac has one, else the current default output.
    private static func clockDeviceUID() throws -> String {
        if let builtIn = allDevices().first(where: { transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasOutput($0) }),
           let uid = uid(builtIn) {
            return uid
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, let uid = uid(device) else { throw CaptureError.systemAudio(status) }
        return uid
    }

    private static func allDevices() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func transportType(_ device: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return value
    }

    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func uid(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

/// A small rolling log at ~/Library/Logs/Luka/audio.log for diagnosing capture problems.
enum AudioLog {
    private static let queue = DispatchQueue(label: "luka.audio-log")
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Luka", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audio.log")
    }()

    static func write(_ message: String) {
        let line = "\(Date.now.formatted(.iso8601)) \(message)\n"
        queue.async {
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
