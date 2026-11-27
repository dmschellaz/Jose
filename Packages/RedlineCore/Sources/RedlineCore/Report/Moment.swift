import Foundation

public struct SentenceRef: Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var start: Double
    public var end: Double
}

/// A clarifying question the live AI asked in Chatty mode, and how it was answered.
public struct Clarification: Codable, Equatable, Sendable {
    public var questionID: UUID
    public var question: String
    public var options: [String]
    /// The option clicked or the sentence said. nil when skipped or never answered.
    public var answer: String?
    /// nil when the question was never closed (e.g. a crashed session).
    public var via: AnswerVia?
    /// When it was asked (seconds since session start).
    public var t: Double

    public var isAnswered: Bool { via == .click || via == .voice }

    public init(questionID: UUID, question: String, options: [String], answer: String? = nil, via: AnswerVia? = nil, t: Double) {
        self.questionID = questionID
        self.question = question
        self.options = options
        self.answer = answer
        self.via = via
        self.t = t
    }
}

public struct Moment: Codable, Equatable, Sendable {
    public var id: Int
    public var start: Double
    public var end: Double
    public var sentences: [SentenceRef]
    public var url: String?
    public var userMarks: [Annotation] = []
    public var aiMarks: [Annotation] = []
    public var clickTimes: [Double] = []
    public var keyframe: KeyframeRef?
    /// Chatty questions about this moment's sentences, in the order asked.
    public var clarifications: [Clarification] = []

    public var text: String { sentences.map(\.text).joined(separator: " ") }

    public init(id: Int, start: Double, end: Double, sentences: [SentenceRef]) {
        self.id = id
        self.start = start
        self.end = end
        self.sentences = sentences
    }
}

public enum MomentSegmenter {
    public static let gap: Double = 4

    public static func segment(_ events: [TimelineEvent]) -> [Moment] {
        let sorted = events.sorted { $0.time < $1.time }

        // 1. Group sentences.
        var groups: [[SentenceRef]] = []
        var current: [SentenceRef] = []
        func close() {
            if !current.isEmpty { groups.append(current); current = [] }
        }
        for e in sorted {
            switch e {
            case let .sentence(id, text, start, end):
                if let last = current.last, start - last.end >= gap { close() }
                current.append(SentenceRef(id: id, text: text, start: start, end: end))
            case .urlChanged, .momentMarked:
                close()
            default:
                break
            }
        }
        close()

        var moments = groups.enumerated().map { i, g in
            Moment(id: i + 1, start: g.first!.start, end: g.last!.end, sentences: g)
        }

        // 2. No speech at all: one moment per explicit mark.
        if moments.isEmpty {
            let anchors: [Double] = sorted.compactMap { e in
                switch e {
                case let .userMark(a): return a.createdAt
                case let .momentMarked(t): return t
                default: return nil
                }
            }
            moments = anchors.enumerated().map { i, t in Moment(id: i + 1, start: t, end: t, sentences: []) }
        }
        guard !moments.isEmpty else { return [] }

        // 3. Attach marks, clicks and questions to their moment.
        func nearest(_ t: Double) -> Int {
            moments.indices.min { distance(t, moments[$0]) < distance(t, moments[$1]) }!
        }
        func owner(of sentenceID: UUID) -> Int? {
            moments.firstIndex { $0.sentences.contains { $0.id == sentenceID } }
        }
        var urls: [(url: String, t: Double)] = []
        var keyframes: [KeyframeRef] = []
        var answers: [UUID: (answer: String, via: AnswerVia)] = [:]
        for e in sorted {
            switch e {
            case let .userMark(a):
                let i = nearest(a.createdAt)
                moments[i].userMarks.append(a)
            case let .aiAnnotation(sentenceID, anns, _):
                // The AI answers one sentence; its marks belong to that sentence's moment.
                let o = owner(of: sentenceID)
                for a in anns {
                    moments[o ?? nearest(a.createdAt)].aiMarks.append(a)
                }
            case let .aiQuestion(id, sentenceID, text, options, t):
                moments[owner(of: sentenceID) ?? nearest(t)].clarifications.append(
                    Clarification(questionID: id, question: text, options: options, t: t))
            case let .questionAnswered(id, answer, via, _):
                answers[id] = (answer, via)
            case let .click(_, _, t):
                let i = nearest(t)
                moments[i].clickTimes.append(t)
            case let .urlChanged(url, _, t): urls.append((url, t))
            case let .keyframe(ref, _): keyframes.append(ref)
            default: break
            }
        }

        // 4. URL, keyframe and answers per moment.
        for i in moments.indices {
            moments[i].url = urls.last(where: { $0.t <= moments[i].start + 1 })?.url ?? urls.first?.url
            moments[i].keyframe = KeyframeSelector.select(for: moments[i], from: keyframes)
            for j in moments[i].clarifications.indices {
                guard let a = answers[moments[i].clarifications[j].questionID] else { continue }
                moments[i].clarifications[j].via = a.via
                moments[i].clarifications[j].answer = a.via == .skipped ? nil : a.answer
            }
        }
        return moments
    }

    static func distance(_ t: Double, _ m: Moment) -> Double {
        if t < m.start { return m.start - t }
        if t > m.end { return t - m.end }
        return 0
    }
}

public enum KeyframeSelector {
    /// The reviewer's own marks win over the live AI's guesses, which win over clicks.
    public static func anchorTime(for m: Moment) -> Double {
        if let t = m.userMarks.map(\.createdAt).max() { return t }
        if let t = m.aiMarks.map(\.createdAt).max() { return t }
        if let t = m.clickTimes.max() { return t + 0.3 }
        return (m.start + m.end) / 2
    }

    public static func select(for m: Moment, from keyframes: [KeyframeRef]) -> KeyframeRef? {
        let anchor = anchorTime(for: m)
        return keyframes.min { a, b in
            let da = abs(a.t - anchor), db = abs(b.t - anchor)
            return da < db || (da == db && a.t > b.t)
        }
    }
}
