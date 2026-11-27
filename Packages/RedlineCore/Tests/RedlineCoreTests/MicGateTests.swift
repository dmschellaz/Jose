import Testing
import Foundation
@testable import RedlineCore

@Suite struct MicGateTests {
    @Test func listensByDefault() {
        #expect(MicGate().isListening())
        #expect(MicGate.defaultTail == .milliseconds(300))
    }

    @Test func closedWhileSpeakingAndForTheTail() {
        let gate = MicGate(tail: .milliseconds(300))
        let t0 = ContinuousClock.now
        gate.close()
        #expect(!gate.isListening(at: t0))
        #expect(!gate.isListening(at: t0 + .seconds(60)))   // stays closed until open
        gate.open(at: t0)
        #expect(!gate.isListening(at: t0 + .milliseconds(299)))
        #expect(gate.isListening(at: t0 + .milliseconds(300)))
    }

    @Test func speakingAgainDuringTheTailClosesIt() {
        let gate = MicGate(tail: .milliseconds(300))
        let t0 = ContinuousClock.now
        gate.close()
        gate.open(at: t0)
        gate.close()
        #expect(!gate.isListening(at: t0 + .seconds(1)))
        gate.open(at: t0 + .seconds(1))
        #expect(!gate.isListening(at: t0 + .milliseconds(1200)))
        #expect(gate.isListening(at: t0 + .milliseconds(1300)))
    }
}
