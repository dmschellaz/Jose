import AppKit
import RedlineCore
import SwiftUI

@MainActor
final class OverlayController: SessionService {
    private var panels: [(panel: NSPanel, model: OverlayModel)] = []
    private var context: SessionContext?
    /// The app that was in front before the pen took over; focus goes back to it on pen-up.
    private var appBeforePen: NSRunningApplication?

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

    /// macOS only lets the active app control the cursor; a background app's NSCursor.set() is
    /// overridden by the frontmost app on the next mouse move. So while the pen is held Redline
    /// becomes the active app (its overlay covers the screen), then hands focus back on pen-up.
    private func updateCursorOwnership(penActive: Bool) {
        if penActive {
            if appBeforePen == nil, let front = NSWorkspace.shared.frontmostApplication,
               front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                appBeforePen = front
            }
            NSApp.activate()
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
            if let previous = appBeforePen {
                appBeforePen = nil
                previous.activate()
            }
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
