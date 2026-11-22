import AppKit
import RedlineCore
import SwiftUI

@MainActor
final class OverlayController: SessionService {
    private var panels: [(panel: NSPanel, model: OverlayModel)] = []
    private var context: SessionContext?
    private var penCursorTimer: Timer?

    func start(context: SessionContext) async throws {
        await stop()
        self.context = context
        showPanels()
    }

    func stop() async {
        setPen(false)
        for p in panels { p.panel.orderOut(nil) }
        panels = []
        context = nil
    }

    func setPen(_ active: Bool) {
        let cursor = CoordinateMapper.quartz(fromCocoa: NSEvent.mouseLocation, primaryHeight: primaryScreenHeight())
        for p in panels {
            let on = active && p.model.display.frame.contains(cursor)
            // Pen released mid-drag: commit the in-progress stroke instead of discarding it.
            if !on, p.model.liveStroke.count > 1 { finishStroke(p.model.liveStroke, on: p.model.display) }
            p.model.penActive = on
            p.panel.ignoresMouseEvents = !on
            if !on { p.model.liveStroke = [] }
        }
        updateCursorOwnership(penActive: active)
    }

    /// Redline never becomes the active app (macOS 14+ refuses activation requests the user didn't
    /// make in Redline), and a background app's NSCursor.set() is normally ignored. BackgroundCursor
    /// opts this process in to setting the cursor from the background; while the pen is held we
    /// re-assert the crosshair at 30 Hz in case the app underneath resets it.
    private func updateCursorOwnership(penActive: Bool) {
        penCursorTimer?.invalidate()
        penCursorTimer = nil
        if penActive {
            BackgroundCursor.enable()
            NSCursor.crosshair.set()
            penCursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                MainActor.assumeIsolated { NSCursor.crosshair.set() }
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    func display(_ annotation: Annotation, lifetime: Double) {
        guard let p = panels.first(where: { $0.model.display.id == annotation.displayID }) else { return }
        p.model.marks.append(ShownMark(annotation: annotation, shownAt: Date(), lifetime: lifetime))
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime + 0.1) { [weak model = p.model] in
            MainActor.assumeIsolated { model?.marks.removeAll { $0.id == annotation.id } }
        }
    }

    private func showPanels() {
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let geo = DisplayGeometry(id: id, frame: CGDisplayBounds(id), scale: screen.backingScaleFactor)
            let model = OverlayModel(display: geo)
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.ignoresMouseEvents = true
            let hosting = NSHostingView(rootView: OverlayView(model: model) { [weak self] points in
                self?.finishStroke(points, on: geo)
            })
            hosting.safeAreaRegions = []   // notched displays: keep SwiftUI (0,0) at the panel's top-left
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append((panel, model))
        }
    }

    private func finishStroke(_ local: [CGPoint], on geo: DisplayGeometry) {
        guard let context else { return }
        let global = local.map { CoordinateMapper.global(fromLocal: $0, on: geo) }
        let annotation = Annotation(shape: .stroke(global), caption: nil, author: .user,
                                    createdAt: context.clock.now(), displayID: geo.id)
        display(annotation, lifetime: 4)
        context.emit(.userMark(annotation))
    }
}
