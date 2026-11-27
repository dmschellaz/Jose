import Foundation

/// Finds the end of each spoken utterance from microphone levels, so the speech recognizer can be told
/// to finalize right away. On its own it waits for long silences: in testing a 2–3 s sentence was
/// held for 10–12 s before it was delivered.
///
/// Feed it consecutive audio chunks (level in dBFS, start time and length in seconds). It returns the
/// time speech stopped once there has been `silenceToEnd` of quiet after at least `minSpeech` of voice.
/// The voice threshold follows the room's noise floor.
public struct SilenceDetector: Sendable {
    public var silenceToEnd: Double
    public var minSpeech: Double
    /// Voice is at least this many dB above the noise floor…
    public var margin: Double = 15
    /// …and never quieter than this.
    public var minVoiceLevel: Double = -55

    private var noiseFloor: Double?
    private var speechStart: Double?
    private var lastVoice: Double = 0

    public init(silenceToEnd: Double = 0.9, minSpeech: Double = 0.25) {
        self.silenceToEnd = silenceToEnd
        self.minSpeech = minSpeech
    }

    public var isInSpeech: Bool { speechStart != nil }

    public mutating func feed(level: Double, at t: Double, duration: Double) -> Double? {
        let level = level.isFinite ? level : -120
        let floor = noiseFloor ?? level
        let voiced = level > max(floor + margin, minVoiceLevel)
        // Track the floor: drop to quieter chunks at once, rise slowly so speech doesn't raise it.
        noiseFloor = level < floor ? level : (voiced ? floor : floor + (level - floor) * 0.02)

        if voiced {
            if speechStart == nil { speechStart = t }
            lastVoice = t + duration
            return nil
        }
        guard let start = speechStart, t + duration - lastVoice >= silenceToEnd else { return nil }
        speechStart = nil
        return lastVoice - start >= minSpeech ? lastVoice : nil
    }

    /// The audio was cut off at `t` (e.g. the mic gate closed). Ends any speech in progress the way `feed`
    /// would, returning when the voice stopped, but never touches the learned noise floor.
    public mutating func interrupt(at t: Double) -> Double? {
        guard let start = speechStart else { return nil }
        speechStart = nil
        let end = min(lastVoice, t)
        return end - start >= minSpeech ? end : nil
    }

    /// Root-mean-square level of float samples in dBFS.
    public static func level(_ samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -120
    }
}
