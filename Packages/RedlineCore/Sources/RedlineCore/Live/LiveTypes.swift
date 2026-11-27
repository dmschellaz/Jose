import CoreGraphics
import Foundation

/// Shared contract for Live mode (phase 2). The LiveAnnotator (RedlineCore), the frame ring buffer
/// (app CaptureService) and the UI (app) all build against these types.

/// A screen frame ready to send to the live model: JPEG at most 1280 px wide, covering one whole display.
public struct LiveFrame: Sendable {
    public var jpeg: Data
    /// Pixel size of `jpeg`; the model's coordinates are in this space.
    public var pixelSize: CGSize
    public var display: DisplayGeometry
    /// Seconds since session start when the frame was captured.
    public var t: Double

    public init(jpeg: Data, pixelSize: CGSize, display: DisplayGeometry, t: Double) {
        self.jpeg = jpeg
        self.pixelSize = pixelSize
        self.display = display
        self.t = t
    }
}

/// A session service that wants to see every timeline event the controller accepts (sentences,
/// clicks, URL changes…). SessionController forwards each accepted event to every started service
/// that conforms, after appending it to the timeline.
@MainActor public protocol TimelineObserving: AnyObject {
    func observe(_ event: TimelineEvent)
}

/// A session service that spends API tokens while recording. SessionController adds these to the
/// session's token total at stop.
@MainActor public protocol TokenReporting: AnyObject {
    var tokensUsed: TokenUsage { get }
    /// The model that served the requests, if any were made.
    var modelUsed: String? { get }
}

/// Whether live annotation is currently working, for the "AI offline" dot.
public enum LiveStatus: Equatable, Sendable {
    case idle      // not in a live session, or nothing sent yet
    case working   // a request is in flight
    case ok        // the last request succeeded
    case offline   // the last request failed or timed out
}

extension TokenUsage {
    public static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output)
    }
}
