import AppKit
import Observation

/// "Paste twice" hand-off for a Claude chat on another computer. Chat apps drop pasted text when the
/// clipboard also holds images, so the write-up and the screenshots go in two pastes: the clipboard
/// starts with the text, and when Redline sees ⌘V it swaps in the screenshots for the second ⌘V.
/// Watches keys with a listen-only event tap (Input Monitoring, which Redline already has).
@MainActor @Observable
final class PasteSequencer {
    enum Step: Equatable {
        case text          // write-up text is on the clipboard, waiting for the first ⌘V
        case screenshots   // screenshots are on the clipboard, waiting for the second ⌘V
        case done
    }

    private(set) var step: Step?
    /// Called after the second paste.
    @ObservationIgnored var onFinished: (() -> Void)?

    @ObservationIgnored private var images: [NSPasteboardItem] = []
    @ObservationIgnored private var ourChangeCount = 0
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// Puts `text` on the clipboard. If there are screenshots, they replace it after the next ⌘V.
    func start(text: String, images: [NSPasteboardItem]) {
        cancel()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ourChangeCount = pb.changeCount
        guard !images.isEmpty, installTap() else {
            step = .done
            return
        }
        self.images = images
        step = .text
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        removeTap()
        images = []
        step = nil
    }

    private func pasted() {
        // Someone copied something else meanwhile: stop, rather than overwrite their clipboard.
        guard NSPasteboard.general.changeCount == ourChangeCount else { return cancel() }
        switch step {
        case .text:
            // Give the target app a moment to read the text before swapping.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.step == .text, NSPasteboard.general.changeCount == self.ourChangeCount else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects(self.images)
                self.ourChangeCount = pb.changeCount
                self.step = .screenshots
                NSSound(named: "Tink")?.play()
            }
        case .screenshots:
            removeTap()
            timeout?.cancel()
            images = []
            step = .done
            onFinished?()
        default:
            break
        }
    }

    // MARK: - Key watching

    private func installTap() -> Bool {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let sequencer = Unmanaged<PasteSequencer>.fromOpaque(refcon).takeUnretainedValue()
                let isPaste = type == .keyDown
                    && event.getIntegerValueField(.keyboardEventKeycode) == 9   // V
                    && event.flags.contains(.maskCommand)
                    && !event.flags.contains(.maskControl) && !event.flags.contains(.maskAlternate)
                let reenable = type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
                MainActor.assumeIsolated {
                    if reenable, let tap = sequencer.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    if isPaste { sequencer.pasted() }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }
}
