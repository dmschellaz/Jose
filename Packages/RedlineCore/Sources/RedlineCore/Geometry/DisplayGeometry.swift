import CoreGraphics

/// A display's frame in global Quartz points (origin top-left of the primary display, y down) and its backing scale.
public struct DisplayGeometry: Codable, Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var scale: Double

    public init(id: UInt32, frame: CGRect, scale: Double) {
        self.id = id
        self.frame = frame
        self.scale = scale
    }
}

/// Every conversion between coordinate spaces goes through here.
/// - global: Quartz points across all displays
/// - pixel: pixels of a full-resolution capture of one display
/// - imagePoint: pixels of an image of arbitrary size covering one display (e.g. downscaled for the API)
/// - local: points relative to one display's top-left (SwiftUI overlay space)
/// - cocoa: AppKit screen points (origin bottom-left of the primary display, y up)
public enum CoordinateMapper {
    public static func pixel(fromGlobal p: CGPoint, on d: DisplayGeometry) -> CGPoint {
        CGPoint(x: (p.x - d.frame.minX) * d.scale, y: (p.y - d.frame.minY) * d.scale)
    }

    public static func global(fromPixel p: CGPoint, on d: DisplayGeometry) -> CGPoint {
        CGPoint(x: p.x / d.scale + d.frame.minX, y: p.y / d.scale + d.frame.minY)
    }

    public static func imagePoint(fromGlobal p: CGPoint, imageSize: CGSize, on d: DisplayGeometry) -> CGPoint {
        CGPoint(x: (p.x - d.frame.minX) * imageSize.width / d.frame.width,
                y: (p.y - d.frame.minY) * imageSize.height / d.frame.height)
    }

    public static func global(fromImagePoint p: CGPoint, imageSize: CGSize, on d: DisplayGeometry) -> CGPoint {
        CGPoint(x: p.x * d.frame.width / imageSize.width + d.frame.minX,
                y: p.y * d.frame.height / imageSize.height + d.frame.minY)
    }

    public static func local(fromGlobal p: CGPoint, on d: DisplayGeometry) -> CGPoint {
        CGPoint(x: p.x - d.frame.minX, y: p.y - d.frame.minY)
    }

    public static func global(fromLocal p: CGPoint, on d: DisplayGeometry) -> CGPoint {
        CGPoint(x: p.x + d.frame.minX, y: p.y + d.frame.minY)
    }

    public static func quartz(fromCocoa p: CGPoint, primaryHeight: Double) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    public static func display(containing p: CGPoint, in displays: [DisplayGeometry]) -> DisplayGeometry? {
        displays.first { $0.frame.contains(p) }
    }
}
