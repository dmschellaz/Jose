import Foundation
import os

/// Lets the microphone pipeline ignore Redline's own voice in Chatty mode (spec §10, "mic gate"). It is
/// closed while a line is spoken and for a short tail after, so the reviewer hears it but it is never transcribed.
///
/// Thread-safe: the audio thread reads it on every buffer, and the main actor opens and closes it.
public final class MicGate: Sendable {
    public static let defaultTail: Duration = .milliseconds(300)

    private struct State: Sendable {
        var closed = false
        var reopensAt: ContinuousClock.Instant?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let tail: Duration

    public init(tail: Duration = MicGate.defaultTail) {
        self.tail = tail
    }

    /// Speaking started: ignore the microphone until `open` plus the tail.
    public func close() {
        state.withLock {
            $0.closed = true
            $0.reopensAt = nil
        }
    }

    /// Speaking ended at `now`: listen again once the tail has passed.
    public func open(at now: ContinuousClock.Instant = .now) {
        let reopensAt = now + tail
        state.withLock {
            $0.closed = false
            $0.reopensAt = reopensAt
        }
    }

    /// Whether microphone input at `now` should be transcribed.
    public func isListening(at now: ContinuousClock.Instant = .now) -> Bool {
        state.withLock { s in
            guard !s.closed else { return false }
            guard let reopensAt = s.reopensAt else { return true }
            return now >= reopensAt
        }
    }
}
