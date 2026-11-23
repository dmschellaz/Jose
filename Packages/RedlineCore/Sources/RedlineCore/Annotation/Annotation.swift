import CoreGraphics
import Foundation

public enum AnnotationShape: Codable, Equatable, Sendable {
    case circle(center: CGPoint, radius: Double)
    case rect(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case highlight(CGRect)
    case stroke([CGPoint])

    /// Maps every point through `f`; lengths (radius) are multiplied by `lengthScale`.
    public func mapped(_ f: (CGPoint) -> CGPoint, lengthScale: Double) -> AnnotationShape {
        func mapRect(_ r: CGRect) -> CGRect {
            let a = f(CGPoint(x: r.minX, y: r.minY))
            let b = f(CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        switch self {
        case let .circle(center, radius): return .circle(center: f(center), radius: radius * lengthScale)
        case let .rect(r): return .rect(mapRect(r))
        case let .arrow(from, to): return .arrow(from: f(from), to: f(to))
        case let .highlight(r): return .highlight(mapRect(r))
        case let .stroke(points): return .stroke(points.map(f))
        }
    }
}

public enum AnnotationAuthor: String, Codable, Sendable {
    case user, ai
}

public struct Annotation: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Points are global Quartz points.
    public var shape: AnnotationShape
    public var caption: String?
    public var author: AnnotationAuthor
    /// Seconds since session start.
    public var createdAt: Double
    public var displayID: UInt32

    public init(id: UUID = UUID(), shape: AnnotationShape, caption: String?, author: AnnotationAuthor, createdAt: Double, displayID: UInt32) {
        self.id = id
        self.shape = shape
        self.caption = caption
        self.author = author
        self.createdAt = createdAt
        self.displayID = displayID
    }
}
