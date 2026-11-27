import CoreGraphics
import Foundation
import os

private let liveLog = Logger(subsystem: "com.dmschellaz.redline", category: "live")

/// Live mode: after each finished sentence, asks the live model what the user means and draws it.
///
/// - At most one request is in flight. A sentence that finishes meanwhile is queued; a newer one replaces it
///   (newest wins). When the in-flight request finishes its marks are still drawn, then the queued one is sent.
/// - A timeout or any error drops the result and sets status `.offline`. Live marks never block the session.
/// - Chatty mode (session mode `.chatty`) sends the same request with the Chatty prompt and schema. Then
///   `ChattyConversation` decides what to say aloud (`onSpeak`) and whether to open a question (`onQuestion`).
///   The open question closes on `answerQuestion`, `skipQuestion`, the reviewer's next sentence, `questionTimeout`
///   or `stop`, and each close is logged as `.questionAnswered`.
@MainActor
public final class LiveAnnotator: SessionService, TimelineObserving, TokenReporting {
    /// Called with each non-empty batch of AI marks (global points), on the main actor.
    public var onMarks: (([Annotation]) -> Void)?
    /// Called once for every sentence the annotator took: with the frame the model saw and its marks (empty
    /// when it marked nothing or failed), or with a nil frame when the sentence was skipped. Main actor.
    public var onResult: ((_ sentenceID: UUID, _ frame: LiveFrame?, _ marks: [Annotation]) -> Void)?
    /// Called whenever `status` changes.
    public var onStatus: ((LiveStatus) -> Void)?
    /// Chatty: a line to read aloud (a short remark, or an open question's text). Main actor.
    public var onSpeak: ((String) -> Void)?
    /// Chatty: the question that just opened, or nil once it is answered, skipped or timed out. Main actor.
    public var onQuestion: ((ChattyConversation.Question?) -> Void)?

    public private(set) var status: LiveStatus = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    public private(set) var tokensUsed = TokenUsage()
    public private(set) var modelUsed: String?
    /// Chatty: the question waiting for an answer, if any.
    public var openQuestion: ChattyConversation.Question? { conversation.open }

    /// Sentences kept as context for the next request.
    static let contextSentences = 3

    private struct Job {
        var sentenceID: UUID
        var text: String
        var start: Double
        var end: Double
        var recent: [String]
        var clicks: [(point: CGPoint, displayID: UInt32)]
        var url: String?
        /// Chatty: the question this sentence answers.
        var answering: String?
    }

    private struct TimedOut: Error {}

    private var llm: (any LLMClient)?
    private var model: String
    private let frame: @MainActor (_ t: Double) async -> LiveFrame?
    private let timeout: Duration
    private let questionTimeout: Duration

    private var context: SessionContext?
    private var recent: [String] = []
    private var clicks: [(point: CGPoint, displayID: UInt32)] = []
    private var url: String?
    private var inFlight: Task<Void, Never>?
    private var queued: Job?
    private var conversation = ChattyConversation()
    /// Skips the open question after `questionTimeout`.
    private var expiry: Task<Void, Never>?
    /// Bumped on start and stop so late results from an earlier session are ignored.
    private var generation = 0

    public init(llm: (any LLMClient)?, model: String,
                frame: @escaping @MainActor (_ t: Double) async -> LiveFrame?,
                timeout: Duration = .seconds(8), questionTimeout: Duration = .seconds(20)) {
        self.llm = llm
        self.model = model
        self.frame = frame
        self.timeout = timeout
        self.questionTimeout = questionTimeout
    }

    /// Changes the client and model for the next session (the API key or Settings may change between sessions).
    public func configure(llm: (any LLMClient)?, model: String) {
        self.llm = llm
        self.model = model
    }

    public func start(context: SessionContext) async throws {
        generation += 1
        resetSession()
        tokensUsed = TokenUsage()
        modelUsed = nil
        guard context.mode != .manual, llm != nil else { return }
        self.context = context
    }

    public func stop() async {
        generation += 1
        inFlight?.cancel()
        if let open = conversation.open { closeQuestion(open.id, answer: "", via: .skipped) }   // ends with the session
        resetSession()
        status = .idle
    }

    /// Chatty: the reviewer clicked an option in the island. Ignored unless `id` is the open question.
    public func answerQuestion(_ id: UUID, _ option: String) {
        closeQuestion(id, answer: option, via: .click)
    }

    /// Chatty: the reviewer clicked Skip. Ignored unless `id` is the open question.
    public func skipQuestion(_ id: UUID) {
        closeQuestion(id, answer: "", via: .skipped)
    }

    public func observe(_ event: TimelineEvent) {
        guard let context else { return }
        switch event {
        case let .sentence(id, text, start, end):
            var answering: String?
            if context.mode == .chatty, let answered = conversation.voiceAnswer(text: text, start: start, at: end) {
                expiry?.cancel()
                expiry = nil
                context.emit(answered.event)
                onQuestion?(nil)
                answering = answered.question.text
            }
            let job = Job(sentenceID: id, text: text, start: start, end: end, recent: recent, clicks: clicks, url: url,
                          answering: answering)
            recent.append(text)
            if recent.count > Self.contextSentences { recent.removeFirst(recent.count - Self.contextSentences) }
            clicks = []
            if inFlight == nil {
                send(job)
            } else {
                if let skipped = queued { onResult?(skipped.sentenceID, nil, []) }   // newest wins
                queued = job
            }
        case let .click(point, displayID, _):
            clicks.append((point, displayID))
        case let .urlChanged(url, _, _):
            self.url = url
        default:
            break
        }
    }

    // MARK: - Private

    private func resetSession() {
        context = nil
        inFlight = nil
        queued = nil
        recent = []
        clicks = []
        url = nil
        conversation.reset()
        expiry?.cancel()
        expiry = nil
    }

    private func closeQuestion(_ id: UUID, answer: String, via: AnswerVia) {
        guard let context, let event = conversation.answer(id, answer, via: via, at: context.clock.now()) else { return }
        expiry?.cancel()
        expiry = nil
        context.emit(event)
        onQuestion?(nil)
    }

    private func scheduleExpiry(of id: UUID, gen: Int) {
        expiry?.cancel()
        let wait = questionTimeout
        expiry = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, gen == self.generation, let context = self.context,
                  let event = self.conversation.expire(id, at: context.clock.now()) else { return }
            self.expiry = nil
            context.emit(event)
            self.onQuestion?(nil)
        }
    }

    private func send(_ job: Job) {
        let gen = generation
        inFlight = Task { [weak self] in
            await self?.run(job, gen: gen)
            guard let self, gen == self.generation else { return }
            self.inFlight = nil
            if let next = self.queued {
                self.queued = nil
                self.send(next)
            }
        }
    }

    private func run(_ job: Job, gen: Int) async {
        guard let llm, let context else { return }
        var seenFrame: LiveFrame?
        var seenMarks: [Annotation] = []
        defer { if gen == generation { onResult?(job.sentenceID, seenFrame, seenMarks) } }
        let wanted = (job.start + job.end) / 2
        guard let frame = await frame(wanted), gen == generation else {
            liveLog.error("No frame for sentence [\(job.start, format: .fixed(precision: 1))–\(job.end, format: .fixed(precision: 1))]; skipped")
            return
        }
        saveFrame(frame, folder: context.folder)
        seenFrame = frame
        let began = ContinuousClock.now
        let chatty = context.mode == .chatty
        let clicks = job.clicks.filter { $0.displayID == frame.display.id }.map(\.point)
        let request = AnnotateRequest.make(model: model, frame: frame, sentence: job.text,
                                           recentSentences: job.recent, clicks: clicks, url: job.url,
                                           chatty: chatty, answering: job.answering)
        status = .working
        do {
            let response = try await Self.send(request, via: llm, timeout: timeout)
            guard gen == generation else { return }
            tokensUsed = tokensUsed + TokenUsage(input: response.usage?.input_tokens ?? 0,
                                                 output: response.usage?.output_tokens ?? 0)
            modelUsed = response.model ?? model
            guard let text = response.firstText() else { throw ClaudeError.noText }
            let answer = try AnnotateRequest.parseAnswer(text, frame: frame, createdAt: job.end)
            let marks = answer.marks
            let elapsed = ContinuousClock.now - began
            liveLog.info("Sentence [\(job.start, format: .fixed(precision: 1))–\(job.end, format: .fixed(precision: 1))] frame t=\(frame.t, format: .fixed(precision: 1)) display \(frame.display.id): \(marks.count) mark(s) in \(elapsed, privacy: .public)")
            if marks.isEmpty { liveLog.info("No marks; model said: \(String(text.prefix(400)), privacy: .public)") }
            status = .ok
            seenMarks = marks
            let outcome = chatty
                ? conversation.respond(say: answer.say, question: answer.question, sentenceID: job.sentenceID,
                                       at: context.clock.now())
                : ChattyConversation.Outcome()
            if !marks.isEmpty {
                context.emit(.aiAnnotation(sentenceID: job.sentenceID, annotations: marks, say: outcome.said))
                onMarks?(marks)
            }
            if let question = outcome.asked {
                context.emit(question.event)
                onQuestion?(question)
                scheduleExpiry(of: question.id, gen: gen)
            }
            if let line = outcome.speak { onSpeak?(line) }
        } catch {
            guard gen == generation else { return }
            liveLog.error("Live request failed: \(String(describing: error), privacy: .public)")
            status = .offline
        }
    }

    /// Keeps the frame the model saw (raw/live-<ms>.jpg), so a missing or misplaced mark can be checked later.
    private func saveFrame(_ frame: LiveFrame, folder: SessionFolder) {
        let url = folder.rawURL.appending(path: "live-\(Int(frame.t * 1000)).jpg")
        let data = frame.jpeg
        Task.detached(priority: .utility) { try? data.write(to: url) }
    }

    /// Races the request against `timeout`; whichever finishes first wins and the other is cancelled.
    private nonisolated static func send(_ request: MessagesRequest, via llm: any LLMClient,
                                         timeout: Duration) async throws -> MessagesResponse {
        try await withThrowingTaskGroup(of: MessagesResponse.self) { group in
            group.addTask { try await llm.send(request) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}
