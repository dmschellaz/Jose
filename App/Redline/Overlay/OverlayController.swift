import AppKit
import RedlineCore
import SwiftUI

@MainActor
final class OverlayController: SessionService {
    private var panels: [(panel: NSPanel, model: OverlayModel)] = []
    private var context: SessionContext?

    func start(context: SessionContext) async throws {
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
            p.model.penActive = on
            p.panel.ignoresMouseEvents = !on
            if !on { p.model.liveStroke = [] }
        }
        (active ? NSCursor.crosshair : NSCursor.arrow).set()
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
            panel.contentView = NSHostingView(rootView: OverlayView(model: model) { [weak self] points in
                self?.finishStroke(points, on: geo)
            })
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append((panel, model))
        }
    }

    private func finishStroke(_ local: [CGPoint], on geo: DisplayGeometry) {
        let global = local.map { CoordinateMapper.global(fromLocal: $0, on: geo) }
        let annotation = Annotation(shape: .stroke(global), caption: nil, author: .user,
                                    createdAt: context?.clock.now() ?? 0, displayID: geo.id)
        display(annotation, lifetime: 4)
        context?.emit(.userMark(annotation))
    }
}
