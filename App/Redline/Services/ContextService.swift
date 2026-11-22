import AppKit
import RedlineCore

enum ContextServiceError: LocalizedError {
    case eventTapUnavailable
    var errorDescription: String? { "Redline needs Input Monitoring permission to notice clicks and the pen key." }
}

@MainActor
final class ContextService: SessionService {
    var onPen: (@MainActor (Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var detector = PenGestureDetector()
    private var urlTimer: Timer?
    private var lastURL: String?
    private var context: SessionContext?

    func start(context: SessionContext) async throws {
        self.context = context
        lastURL = nil
        detector = PenGestureDetector()

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<ContextService>.fromOpaque(refcon).takeUnretainedValue()
                let location = event.location
                let flags = event.flags
                MainActor.assumeIsolated { service.handle(type: type, location: location, flags: flags) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon) else { throw ContextServiceError.eventTapUnavailable }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        urlTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollURL() }
        }
        pollURL()
    }

    func stop() async {
        urlTimer?.invalidate()
        urlTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        if detector.isActive { onPen?(false) }
        context = nil
    }

    private func handle(type: CGEventType, location: CGPoint, flags: CGEventFlags) {
        guard let context else { return }
        let t = context.clock.now()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            guard !detector.isActive else { return }
            var displayID: CGDirectDisplayID = 0
            var count: UInt32 = 0
            CGGetDisplaysWithPoint(location, 1, &displayID, &count)
            context.emit(.click(point: location, displayID: displayID, t: t))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.pollURL() }
            }
        case .flagsChanged:
            apply(detector.flagsChanged(Self.modifiers(flags), at: t))
            if detector.isPending {
                DispatchQueue.main.asyncAfter(deadline: .now() + detector.holdDelay + 0.01) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let clock = self.context?.clock else { return }
                        self.apply(self.detector.tick(at: clock.now()))
                    }
                }
            }
        case .keyDown:
            apply(detector.keyDown(at: t))
        default:
            break
        }
    }

    private func apply(_ output: PenGestureDetector.Output) {
        switch output {
        case .penDown: onPen?(true)
        case .penUp: onPen?(false)
        case .none: break
        }
    }

    private func pollURL() {
        guard let context,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              BrowserURLReader.supports(bundleID),
              let page = BrowserURLReader.read(bundleID: bundleID),
              page.url != lastURL else { return }
        lastURL = page.url
        context.emit(.urlChanged(url: page.url, title: page.title, t: context.clock.now()))
    }

    private static func modifiers(_ f: CGEventFlags) -> ModifierFlags {
        var m: ModifierFlags = []
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskShift) { m.insert(.shift) }
        if f.contains(.maskSecondaryFn) { m.insert(.function) }
        return m
    }
}
