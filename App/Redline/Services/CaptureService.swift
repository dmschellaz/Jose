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

    // Live ring buffer (every mode but .manual).
    nonisolated static let liveMaxWidth = 1280
    /// A buffered frame further than this from the requested time is too stale; take a fresh one.
    static let liveMaxFrameAge: Double = 3
    private let ring = FrameRingBuffer()
    private let sampleQueue = DispatchQueue(label: "Redline.CaptureService.live", qos: .userInitiated)
    private var stream: SCStream?
    private var streamOutput: LiveStreamOutput?
    private var cursorPoll: Task<Void, Never>?

    func start(context: SessionContext) async throws {
        _ = try await refresh()   // fails fast if Screen Recording isn't granted
        self.context = context
        if context.mode != .manual {
            cursorPoll = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.followCursor()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    func stop() async {
        // Let the poll loop finish any stream restart in flight before tearing the stream down.
        cursorPoll?.cancel()
        await cursorPoll?.value
        cursorPoll = nil
        await stopStream()
        ring.removeAll()
        context = nil
    }

    /// The buffered frame nearest `t` (seconds since session start) as a JPEG at most 1280 px wide.
    /// Falls back to a fresh capture of the display under the cursor when nothing buffered is within 3 s.
    func liveFrame(near t: Double) async -> LiveFrame? {
        guard context != nil else { return nil }
        if let frame = ring.nearest(to: t), abs(frame.t - t) <= Self.liveMaxFrameAge {
            return await Self.encode(frame)
        }
        guard let frame = await freshFrame() else { return nil }
        return await Self.encode(frame)
    }

    private nonisolated static func encode(_ frame: BufferedFrame) async -> LiveFrame? {
        await Task.detached(priority: .userInitiated) { () -> LiveFrame? in
            // Downscale first so pixelSize is exactly the JPEG's size (jpegData then leaves it alone).
            let image = ImageFiles.downscaled(frame.image, maxWidth: liveMaxWidth)
            guard let jpeg = ImageFiles.jpegData(image, maxWidth: liveMaxWidth) else { return nil }
            return LiveFrame(jpeg: jpeg, pixelSize: CGSize(width: image.width, height: image.height),
                             display: frame.display, t: frame.t)
        }.value
    }

    private func freshFrame() async -> BufferedFrame? {
        guard let context else { return nil }
        let cursor = CoordinateMapper.quartz(fromCocoa: NSEvent.mouseLocation, primaryHeight: primaryScreenHeight())
        do {
            let content = try await refresh()
            guard let geo = CoordinateMapper.display(containing: cursor, in: displays) ?? nearestDisplay(to: cursor),
                  let filter = contentFilter(for: geo, in: content) else { return nil }
            let t = context.clock.now()
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: liveConfiguration(for: geo))
            return BufferedFrame(image: image, t: t, display: geo)
        } catch {
            NSLog("Redline: live fallback capture failed: \(error)")
            return nil
        }
    }

    /// Keeps the stream on the display under the cursor; (re)starts it if it isn't running.
    private func followCursor() async {
        guard let context else { return }
        let cursor = CoordinateMapper.quartz(fromCocoa: NSEvent.mouseLocation, primaryHeight: primaryScreenHeight())
        let current = streamOutput?.display
        if let current, stream != nil, current.frame.contains(cursor) { return }
        do {
            let content = try await refresh()
            guard let geo = CoordinateMapper.display(containing: cursor, in: displays) ?? nearestDisplay(to: cursor),
                  geo != current || stream == nil,
                  let filter = contentFilter(for: geo, in: content) else { return }
            await stopStream()

            let output = LiveStreamOutput(display: geo, buffer: ring, clock: context.clock) { [weak self] error in
                NSLog("Redline: live stream stopped: \(error)")
                Task { @MainActor in self?.streamDidStop(geo) }
            }
            let newStream = SCStream(filter: filter, configuration: liveConfiguration(for: geo, fps: 2), delegate: output)
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            // Record it before awaiting so stop() can always tear it down.
            stream = newStream
            streamOutput = output
            try await newStream.startCapture()
        } catch {
            NSLog("Redline: live stream start failed: \(error)")
            stream = nil
            streamOutput = nil
        }
    }

    private func streamDidStop(_ display: DisplayGeometry) {
        // Only forget the stream if it is still the one that failed; the poll loop restarts it.
        guard streamOutput?.display == display else { return }
        stream = nil
        streamOutput = nil
    }

    private func stopStream() async {
        guard let stream else { return }
        let output = streamOutput   // SCStream holds its output weakly: keep it alive until capture stops
        self.stream = nil
        streamOutput = nil
        do { try await stream.stopCapture() } catch { /* already stopped */ }
        withExtendedLifetime(output) {}
    }

    private func contentFilter(for geo: DisplayGeometry, in content: SCShareableContent) -> SCContentFilter? {
        guard let scDisplay = content.displays.first(where: { $0.displayID == geo.id }) else { return nil }
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        return SCContentFilter(display: scDisplay, excludingApplications: ownApps, exceptingWindows: [])
    }

    /// Point size, capped at 1280 px wide: plenty for the live model and cheap to hold 20 of.
    private func liveConfiguration(for geo: DisplayGeometry, fps: Int32? = nil) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let width = min(Double(Self.liveMaxWidth), geo.frame.width)
        config.width = max(1, Int(width.rounded()))
        config.height = max(1, Int((geo.frame.height * width / geo.frame.width).rounded()))
        config.showsCursor = true
        if let fps {
            config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 4
        }
        return config
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
