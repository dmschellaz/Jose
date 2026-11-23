import CoreGraphics
import CoreMedia
import Foundation
import RedlineCore
import ScreenCaptureKit
import Synchronization
import VideoToolbox

/// One frame held by the live ring buffer: the raw image, when it was captured, and which display it shows.
struct BufferedFrame: @unchecked Sendable {   // CGImage is immutable and thread-safe
    let image: CGImage
    let t: Double
    let display: DisplayGeometry
}

/// The last `window` seconds of live frames. Written from the SCStream sample queue, read from the
/// main actor; every access goes through the mutex, so it is safe from any thread.
final class FrameRingBuffer: Sendable {
    static let window: Double = 10
    /// Hard cap in case timestamps misbehave: 10 s at 2 fps is 20 frames, plus slack.
    static let maxFrames = 30

    private let frames = Mutex<[BufferedFrame]>([])

    func append(_ frame: BufferedFrame) {
        frames.withLock { frames in
            frames.append(frame)
            let cutoff = frame.t - Self.window
            frames.removeAll { $0.t < cutoff }
            if frames.count > Self.maxFrames { frames.removeFirst(frames.count - Self.maxFrames) }
        }
    }

    func nearest(to t: Double) -> BufferedFrame? {
        frames.withLock { frames in frames.min { abs($0.t - t) < abs($1.t - t) } }
    }

    func removeAll() {
        frames.withLock { $0.removeAll() }
    }
}

/// Receives SCStream frames for one display on a private serial queue and feeds the ring buffer.
/// All stored state is immutable or mutex-protected, so it is genuinely Sendable.
final class LiveStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let display: DisplayGeometry
    private let buffer: FrameRingBuffer
    private let clock: SessionClock
    private let onStop: @Sendable (Error) -> Void
    /// The last complete image, re-stamped on `.idle` frames: SCStream sends no new pixels while the
    /// screen is static, and without this the buffer would go stale and every request would fall back
    /// to a fresh capture.
    private let lastImage = Mutex<CGImage?>(nil)

    init(display: DisplayGeometry, buffer: FrameRingBuffer, clock: SessionClock,
         onStop: @escaping @Sendable (Error) -> Void) {
        self.display = display
        self.buffer = buffer
        self.clock = clock
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let t = clock.now()
        switch Self.status(of: sampleBuffer) {
        case .complete:
            guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
            guard let image = Self.copyImage(from: pixelBuffer) else { return }
            lastImage.withLock { $0 = image }
            buffer.append(BufferedFrame(image: image, t: t, display: display))
        case .idle:
            if let image = lastImage.withLock({ $0 }) {
                buffer.append(BufferedFrame(image: image, t: t, display: display))
            }
        default:
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }

    /// Converts the frame to a CGImage that owns its pixels. The image VideoToolbox returns can keep the
    /// IOSurface-backed pixel buffer alive, and holding 20 of those would drain SCStream's small
    /// buffer pool (queueDepth) and stall the stream, so it is redrawn into a plain bitmap.
    private static func copyImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        var wrapped: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &wrapped)
        guard let wrapped,
              let ctx = CGContext(data: nil, width: wrapped.width, height: wrapped.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: wrapped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(wrapped, in: CGRect(x: 0, y: 0, width: wrapped.width, height: wrapped.height))
        return ctx.makeImage()
    }

    private static func status(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }
}
