import Testing
@testable import RedlineCore

/// Feeds 85 ms chunks: each tuple is (level dBFS, seconds).
private func run(_ d: inout SilenceDetector, _ spans: [(Double, Double)]) -> [Double] {
    let chunk = 0.085
    var t = 0.0, ends: [Double] = []
    for (level, length) in spans {
        let stop = t + length
        while t < stop - 1e-9 {
            if let e = d.feed(level: level, at: t, duration: chunk) { ends.append(e) }
            t += chunk
        }
    }
    return ends
}

@Suite struct SilenceDetectorTests {
    @Test func endsAnUtteranceAfterTheSilence() {
        var d = SilenceDetector(silenceToEnd: 0.9)
        let ends = run(&d, [(-65, 1), (-25, 2.5), (-65, 2)])
        #expect(ends.count == 1)
        #expect(abs(ends[0] - 3.5) < 0.1)   // when the voice stopped, not when the silence was noticed
    }

    @Test func shortPausesDoNotSplitASentence() {
        var d = SilenceDetector(silenceToEnd: 0.9)
        let ends = run(&d, [(-65, 1), (-25, 1), (-62, 0.5), (-25, 1), (-65, 2)])
        #expect(ends.count == 1)
    }

    @Test func twoSentencesGiveTwoEnds() {
        var d = SilenceDetector()
        #expect(run(&d, [(-65, 1), (-25, 2), (-65, 1.5), (-28, 2), (-65, 1.5)]).count == 2)
    }

    @Test func clicksAndBlipsAreNotSpeech() {
        var d = SilenceDetector(minSpeech: 0.25)
        #expect(run(&d, [(-65, 1), (-20, 0.085), (-65, 2)]).isEmpty)
    }

    @Test func noisyRoomFollowsTheFloor() {
        var d = SilenceDetector()
        // Fan noise at -45 dB would count as voice against a fixed -55 threshold.
        let ends = run(&d, [(-45, 2), (-20, 2), (-45, 2)])
        #expect(ends.count == 1)
    }

    @Test func levelOfSamples() {
        let full: [Float] = Array(repeating: 1, count: 100)
        let silent: [Float] = Array(repeating: 0, count: 100)
        full.withUnsafeBufferPointer { #expect(abs(SilenceDetector.level($0)) < 0.001) }
        silent.withUnsafeBufferPointer { #expect(SilenceDetector.level($0) == -120) }
    }
}
