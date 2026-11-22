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
        self.context = context
        _ = try await refresh()   // fails fast if Screen Recording isn't granted
    }

    func stop() async {
        context = nil
    }

    func captureKeyframe(reason: KeyframeReason) async -> TimelineEvent? {
        guard let context else { return nil }
        do {
            let content = try await refresh()
            let cursor = CoordinateMapper.quartz(fromCocoa: NSEvent.mouseLocation, primaryHeight: primaryScreenHeight())
            guard let geo = CoordinateMapper.display(containing: cursor, in: displays) ?? displays.first,
                  let scDisplay = content.displays.first(where: { $0.displayID == geo.id }) else { return nil }

            let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            let filter = SCContentFilter(display: scDisplay, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(geo.frame.width * geo.scale)
            config.height = Int(geo.frame.height * geo.scale)
            config.showsCursor = true

            let t = context.clock.now()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let file = "kf-\(Int(t * 1000))-\(reason.rawValue).png"
            try ImageFiles.writePNG(image, to: context.folder.rawURL.appending(path: file))
            return .keyframe(KeyframeRef(id: UUID(), file: file, t: t, displayID: geo.id), reason: reason)
        } catch {
            NSLog("Redline: capture failed: \(error)")
            return nil
        }
    }

    private func refresh() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        displays = content.displays.map { d in
            let bounds = CGDisplayBounds(d.displayID)
            let scale = CGDisplayCopyDisplayMode(d.displayID).map { Double($0.pixelWidth) / Double($0.width) } ?? 2
            return DisplayGeometry(id: d.displayID, frame: bounds, scale: scale)
        }
        return content
    }
}
