import CoreGraphics
import Foundation

public enum KeyframeReason: String, Codable, Sendable {
    case click, sentence, mark, pen, periodic
}

public struct KeyframeRef: Codable, Equatable, Sendable {
    public var id: UUID
    /// File name inside the session's raw/ folder.
    public var file: String
    public var t: Double
    public var displayID: UInt32

    public init(id: UUID, file: String, t: Double, displayID: UInt32) {
        self.id = id
        self.file = file
        self.t = t
        self.displayID = displayID
    }
}

/// Everything that happens during a session. All times are seconds since session start.
public enum TimelineEvent: Codable, Equatable, Sendable {
    case sentence(id: UUID, text: String, start: Double, end: Double)
    case click(point: CGPoint, displayID: UInt32, t: Double)
    case urlChanged(url: String, title: String?, t: Double)
    case keyframe(KeyframeRef, reason: KeyframeReason)
    case userMark(Annotation)
    case aiAnnotation(sentenceID: UUID, annotations: [Annotation], say: String?)
    case momentMarked(t: Double)

    public var time: Double {
        switch self {
        case let .sentence(_, _, start, _): return start
        case let .click(_, _, t): return t
        case let .urlChanged(_, _, t): return t
        case let .keyframe(ref, _): return ref.t
        case let .userMark(a): return a.createdAt
        case let .aiAnnotation(_, annotations, _): return annotations.first?.createdAt ?? 0
        case let .momentMarked(t): return t
        }
    }
}
