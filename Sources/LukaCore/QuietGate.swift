/// Decides when a stream has been quiet long enough to stop paying for it, and when sound is back.
/// Fed one level (0…1, −60 dBFS = 0) per 100 ms chunk.
public struct QuietGate: Sendable {
    /// −45 dBFS: above a quiet room's floor, below speech even at a distance.
    public static let soundLevel: Float = 0.25
    /// Sound in this many of the last ten chunks wakes the stream; a click or a cough does not.
    static let wakeChunks = 3

    public let sleepAfter: Int
    private var quietChunks = 0
    private var recent: [Bool] = []

    public init(sleepAfterSeconds seconds: Int = 180) {
        sleepAfter = seconds * 10
    }

    /// While streaming. True once there has been neither sound nor speech for `sleepAfter`.
    public mutating func listen(level: Float) -> Bool {
        quietChunks = level > Self.soundLevel ? 0 : quietChunks + 1
        return quietChunks >= sleepAfter
    }

    /// Soniox recognized words, however soft the audio was.
    public mutating func heardSpeech() {
        quietChunks = 0
    }

    /// While asleep. True once sound is back.
    public mutating func wake(level: Float) -> Bool {
        recent.append(level > Self.soundLevel)
        if recent.count > 10 { recent.removeFirst() }
        return recent.count(where: { $0 }) >= Self.wakeChunks
    }

    public mutating func reset() {
        quietChunks = 0
        recent.removeAll()
    }
}
