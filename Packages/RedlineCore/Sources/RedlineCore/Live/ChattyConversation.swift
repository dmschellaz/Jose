import Foundation

/// Chatty mode's turn-taking rules (spec §10), kept apart from the network code so they can be tested with
/// plain times (seconds since session start).
///
/// - A short remark is spoken at most once every `lineInterval` seconds. Questions skip that limit, and asking
///   one counts as the last spoken line.
/// - Only one clarifying question is open at a time. A new one while another is open is dropped; that answer's
///   remark may still be spoken. When a question opens, only its text is spoken.
/// - The open question closes on a click (`answer`), on the reviewer's next sentence that started after it was
///   asked (`voiceAnswer`), or as skipped (`answer(_:_:via: .skipped,…)` or `expire`). Every close names the
///   question id, so a late click or timeout for an old question cannot close a newer one.
public struct ChattyConversation: Sendable {
    public static let lineInterval: Double = 10

    public struct Question: Equatable, Sendable, Identifiable {
        public var id: UUID
        /// The sentence the question is about.
        public var sentenceID: UUID
        public var text: String
        public var options: [String]
        /// When it was asked.
        public var askedAt: Double

        /// The timeline event that logs this question.
        public var event: TimelineEvent {
            .aiQuestion(id: id, sentenceID: sentenceID, text: text, options: options, t: askedAt)
        }
    }

    /// What to do with one live answer.
    public struct Outcome: Equatable, Sendable {
        /// A question that was just opened.
        public var asked: Question?
        /// What to speak now, if anything.
        public var speak: String?
        /// The remark that was spoken, for `aiAnnotation.say`. nil when silent or when a question was spoken.
        public var said: String?

        public init(asked: Question? = nil, speak: String? = nil, said: String? = nil) {
            self.asked = asked
            self.speak = speak
            self.said = said
        }
    }

    public private(set) var open: Question?
    private var lastSpokenAt: Double?

    public init() {}

    public mutating func reset() {
        open = nil
        lastSpokenAt = nil
    }

    /// Decides what to say for the live answer to `sentenceID`, received at `t`.
    public mutating func respond(say: String, question: LiveQuestion?, sentenceID: UUID, at t: Double) -> Outcome {
        if let question, open == nil {
            let q = Question(id: UUID(), sentenceID: sentenceID, text: question.text, options: question.options, askedAt: t)
            open = q
            lastSpokenAt = t
            return Outcome(asked: q, speak: q.text)
        }
        let line = say.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, lastSpokenAt.map({ t - $0 >= Self.lineInterval }) ?? true else { return Outcome() }
        lastSpokenAt = t
        return Outcome(speak: line, said: line)
    }

    /// Closes question `id` with `answer` (a clicked option, or "" with `.skipped`). nil unless `id` is the open
    /// question, or when `via` is `.voice` (voice answers go through `voiceAnswer`).
    public mutating func answer(_ id: UUID, _ answer: String, via: AnswerVia, at t: Double) -> TimelineEvent? {
        guard via != .voice, let q = open, q.id == id else { return nil }
        open = nil
        return .questionAnswered(id: q.id, answer: answer, via: via, t: t)
    }

    /// The 20 s timeout: skips question `id` if it is still the open one.
    public mutating func expire(_ id: UUID, at t: Double) -> TimelineEvent? {
        guard open?.id == id else { return nil }
        return answer(id, "", via: .skipped, at: t)
    }

    /// A finished sentence answers the open question if it started at or after the question was asked.
    public mutating func voiceAnswer(text: String, start: Double, at t: Double) -> (question: Question, event: TimelineEvent)? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let q = open, start >= q.askedAt else { return nil }
        open = nil
        return (q, .questionAnswered(id: q.id, answer: line, via: .voice, t: t))
    }
}
