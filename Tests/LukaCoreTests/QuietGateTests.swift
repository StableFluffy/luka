import Testing
@testable import LukaCore

@Suite struct QuietGateTests {
    private let quiet: Float = 0.1
    private let sound: Float = 0.6

    /// Index of the first chunk the gate says yes to, if any.
    private func firstYes(_ levels: [Float], _ step: (Float) -> Bool) -> Int? {
        levels.indices.first { step(levels[$0]) }
    }

    @Test func sleepsOnlyAfterTheFullQuietStretch() {
        var gate = QuietGate(sleepAfterSeconds: 180)
        #expect(firstYes(Array(repeating: quiet, count: 2_000)) { gate.listen(level: $0) } == 1_799)
    }

    @Test func soundOrSpeechRestartsTheClock() {
        var gate = QuietGate(sleepAfterSeconds: 10)
        let levels = Array(repeating: quiet, count: 99) + [sound] + Array(repeating: quiet, count: 99)
        #expect(firstYes(levels) { gate.listen(level: $0) } == nil)
        gate.heardSpeech()
        #expect(firstYes(Array(repeating: quiet, count: 200)) { gate.listen(level: $0) } == 99)
    }

    @Test func briefNoiseDoesNotWake() {
        var gate = QuietGate()
        let clicks = (0..<100).map { $0 % 10 < 2 ? sound : quiet }
        #expect(firstYes(clicks) { gate.wake(level: $0) } == nil)
    }

    @Test func sustainedSoundWakes() {
        var gate = QuietGate()
        #expect(firstYes([sound, quiet, sound, sound, sound]) { gate.wake(level: $0) } == 3)
    }
}
