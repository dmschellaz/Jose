import Testing
@testable import RedlineCore

@Test func optionAloneAfterDelayActivates() {
    var d = PenGestureDetector()
    #expect(d.flagsChanged(.option, at: 0) == .none)
    #expect(d.tick(at: 0.1) == .none)
    #expect(d.tick(at: 0.16) == .penDown)
    #expect(d.isActive)
    #expect(d.flagsChanged([], at: 1) == .penUp)
    #expect(!d.isActive)
}

@Test func quickTapDoesNothing() {
    var d = PenGestureDetector()
    _ = d.flagsChanged(.option, at: 0)
    #expect(d.flagsChanged([], at: 0.05) == .none)
    #expect(d.tick(at: 0.2) == .none)
}

@Test func controlOptionShortcutNeverActivates() {
    var d = PenGestureDetector()
    _ = d.flagsChanged(.control, at: 0)
    _ = d.flagsChanged([.control, .option], at: 0.01)
    #expect(d.tick(at: 0.5) == .none)
    // option first, then control quickly (⌥⌃F typed in the other order)
    var e = PenGestureDetector()
    _ = e.flagsChanged(.option, at: 0)
    _ = e.flagsChanged([.option, .control], at: 0.05)
    #expect(e.tick(at: 0.5) == .none)
    // releasing control but still holding option stays suppressed
    #expect(e.flagsChanged(.option, at: 0.6) == .none)
    #expect(e.tick(at: 1) == .none)
}

@Test func typingWithOptionCancels() {
    var d = PenGestureDetector()
    _ = d.flagsChanged(.option, at: 0)
    #expect(d.keyDown(at: 0.05) == .none)
    #expect(d.tick(at: 0.5) == .none)
}

@Test func keyOrModifierWhileActiveEndsPen() {
    var d = PenGestureDetector()
    _ = d.flagsChanged(.option, at: 0)
    _ = d.tick(at: 0.2)
    #expect(d.keyDown(at: 0.3) == .penUp)
    var e = PenGestureDetector()
    _ = e.flagsChanged(.option, at: 0)
    _ = e.tick(at: 0.2)
    #expect(e.flagsChanged([.option, .command], at: 0.3) == .penUp)
}
