import AppKit
import RedlineCore
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor func primaryScreenHeight() -> Double {
    Double(NSScreen.screens.first?.frame.height ?? 0)
}

@MainActor
final class CaptureService: FrameCapturing {
    private(set) var displays: [DisplayGeometry] = []
    private var context: SessionContext?

    func start(context: SessionContext) async throws {
        _ = try await refresh()   // fails fast if Screen Recording isn't granted
        self.context = context
    }

    func stop() async {
        context = nil
    }

    func captureKeyframe(reason: KeyframeReason) async -> TimelineEvent? {
        guard let context else { return nil }
        // Sample the cursor before any await so it can't move displays underneath us.
        let cursor = CoordinateMapper.quartz(fromCocoa: NSEvent.mouseLocation, primaryHeight: primaryScreenHeight())
        do {
            let content = try await refresh()
            guard let geo = CoordinateMapper.display(containing: cursor, in: displays) ?? nearestDisplay(to: cursor),
                  let scDisplay = content.displays.first(where: { $0.displayID == geo.id }) else { return nil }

            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: scDisplay, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int((geo.frame.width * geo.scale).rounded())
            config.height = Int((geo.frame.height * geo.scale).rounded())
            config.showsCursor = true

            let t = context.clock.now()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let file = "kf-\(Int(t * 1000))-\(reason.rawValue).png"
            let url = context.folder.rawURL.appending(path: file)
            try await Task.detached(priority: .utility) { try ImageFiles.writePNG(image, to: url) }.value
            return .keyframe(KeyframeRef(id: UUID(), file: file, t: t, displayID: geo.id), reason: reason)
        } catch {
            NSLog("Redline: capture failed: \(error)")
            return nil
        }
    }

    /// Display whose frame is closest to the point (distance 0 if inside); handles points on a max edge.
    private func nearestDisplay(to p: CGPoint) -> DisplayGeometry? {
        displays.min { a, b in distance(from: p, to: a.frame) < distance(from: p, to: b.frame) }
    }

    private func distance(from p: CGPoint, to r: CGRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return Double((dx * dx + dy * dy).squareRoot())
    }

    private func refresh() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        displays = content.displays.map { d in
            let bounds = CGDisplayBounds(d.displayID)
            let scale = CGDisplayCopyDisplayMode(d.displayID).map { Double($0.pixelWidth) / Double($0.width) } ?? 1
            return DisplayGeometry(id: d.displayID, frame: bounds, scale: scale)
        }
        return content
    }
}
