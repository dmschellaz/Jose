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

/// How a Chatty clarifying question was closed.
public enum AnswerVia: String, Codable, Sendable {
    /// The reviewer clicked one of the options in the island.
    case click
    /// The reviewer's next finished sentence was taken as the answer.
    case voice
    /// Skip was clicked, nobody answered within 20 s, or the session ended first.
    case skipped
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
    /// Chatty: the live AI asked about sentence `sentenceID`; `options` are the 2–3 answer buttons.
    case aiQuestion(id: UUID, sentenceID: UUID, text: String, options: [String], t: Double)
    /// Chatty: question `id` was closed. `answer` is the option clicked or the sentence said, "" when skipped.
    case questionAnswered(id: UUID, answer: String, via: AnswerVia, t: Double)

    public var time: Double {
        switch self {
        case let .sentence(_, _, start, _): return start
        case let .click(_, _, t): return t
        case let .urlChanged(_, _, t): return t
        case let .keyframe(ref, _): return ref.t
        case let .userMark(a): return a.createdAt
        case let .aiAnnotation(_, annotations, _): return annotations.first?.createdAt ?? 0
        case let .momentMarked(t): return t
        case let .aiQuestion(_, _, _, _, t): return t
        case let .questionAnswered(_, _, _, t): return t
        }
    }
}
