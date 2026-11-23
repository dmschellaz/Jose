import CoreGraphics
import Foundation
import os

private let liveLog = Logger(subsystem: "com.dmschellaz.redline", category: "live")

/// Live mode: after each finished sentence, asks the live model what the user means and draws it.
///
/// - At most one request is in flight. A sentence that finishes meanwhile is queued; a newer one replaces it
///   (newest wins). When the in-flight request finishes its marks are still drawn, then the queued one is sent.
/// - A timeout or any error drops the result and sets status `.offline`. Live marks never block the session.
@MainActor
public final class LiveAnnotator: SessionService, TimelineObserving, TokenReporting {
    /// Called with each non-empty batch of AI marks (global points), on the main actor.
    public var onMarks: (([Annotation]) -> Void)?
    /// Called once for every sentence the annotator took: with the frame the model saw and its marks (empty
    /// when it marked nothing or failed), or with a nil frame when the sentence was skipped. Main actor.
    public var onResult: ((_ sentenceID: UUID, _ frame: LiveFrame?, _ marks: [Annotation]) -> Void)?
    /// Called whenever `status` changes.
    public var onStatus: ((LiveStatus) -> Void)?

    public private(set) var status: LiveStatus = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }
    public private(set) var tokensUsed = TokenUsage()
    public private(set) var modelUsed: String?

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
        /// Sent early from a settled partial transcript, before the sentence was final.
        var speculative = false
    }

    /// An early request made from a settled partial transcript. When the final sentence matches, its
    /// answer is used for that sentence instead of sending again.
    private struct Speculation {
        var key: String           // normalized text
        var jobID: UUID
        var done = false
        var frame: LiveFrame?
        var marks: [Annotation] = []
        /// The final sentence that adopted it while it was still in flight.
        var adoptedBy: (id: UUID, end: Double)?
    }

    private struct TimedOut: Error {}

    private var llm: (any LLMClient)?
    private var model: String
    private let frame: @MainActor (_ t: Double) async -> LiveFrame?
    private let timeout: Duration

    private var context: SessionContext?
    private var recent: [String] = []
    private var clicks: [(point: CGPoint, displayID: UInt32)] = []
    private var url: String?
    private var inFlight: Task<Void, Never>?
    private var queued: Job?
    private var speculation: Speculation?
    /// Bumped on start and stop so late results from an earlier session are ignored.
    private var generation = 0

    public init(llm: (any LLMClient)?, model: String,
                frame: @escaping @MainActor (_ t: Double) async -> LiveFrame?,
                timeout: Duration = .seconds(8)) {
        self.llm = llm
        self.model = model
        self.frame = frame
        self.timeout = timeout
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
        resetSession()
        status = .idle
    }

    public func observe(_ event: TimelineEvent) {
        guard context != nil else { return }
        switch event {
        case let .sentence(id, text, start, end):
            if adopt(sentenceID: id, text: text, end: end) {
                recent.append(text)
                if recent.count > Self.contextSentences { recent.removeFirst(recent.count - Self.contextSentences) }
                clicks = []
                return
            }
            speculation = nil
            let job = Job(sentenceID: id, text: text, start: start, end: end, recent: recent, clicks: clicks, url: url)
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

    /// The live transcript has stopped changing: start annotating now rather than waiting for the
    /// recognizer to finalize the sentence (that takes 1–4 s). Only when nothing else is in flight.
    public func speculate(text: String, start: Double, end: Double) {
        guard context != nil, inFlight == nil, queued == nil else { return }
        let key = Self.normalize(text)
        guard key.count >= 3, key != speculation?.key else { return }
        let job = Job(sentenceID: UUID(), text: text, start: start, end: end, recent: recent, clicks: clicks,
                      url: url, speculative: true)
        speculation = Speculation(key: key, jobID: job.sentenceID)
        send(job)
    }

    // MARK: - Private

    /// Lowercased words only, so punctuation and capitalisation changes at finalization still match.
    nonisolated static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// The final text is the speculated one, give or take a word or two at the end.
    nonisolated static func sameSentence(_ speculated: String, _ final: String) -> Bool {
        if speculated == final { return true }
        let (short, long) = speculated.count <= final.count ? (speculated, final) : (final, speculated)
        return long.hasPrefix(short) && Double(short.count) >= Double(long.count) * 0.8
    }

    /// Uses the early answer for this sentence if it was about the same words. Returns false if not.
    private func adopt(sentenceID id: UUID, text: String, end: Double) -> Bool {
        guard var spec = speculation, Self.sameSentence(spec.key, Self.normalize(text)) else { return false }
        if spec.done {
            speculation = nil
            deliver(sentenceID: id, end: end, frame: spec.frame, marks: spec.marks)
        } else {
            spec.adoptedBy = (id, end)
            speculation = spec
        }
        return true
    }

    /// Records marks for a final sentence (timeline + feed). Marks were already drawn when they arrived.
    private func deliver(sentenceID id: UUID, end: Double, frame: LiveFrame?, marks: [Annotation]) {
        let marks = marks.map { var a = $0; a.createdAt = end; return a }
        if !marks.isEmpty { context?.emit(.aiAnnotation(sentenceID: id, annotations: marks, say: nil)) }
        onResult?(id, frame, marks)
    }

    private func resetSession() {
        context = nil
        inFlight = nil
        queued = nil
        speculation = nil
        recent = []
        clicks = []
        url = nil
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
        defer {
            if gen == generation {
                if job.speculative { finishSpeculation(job.sentenceID, frame: seenFrame, marks: seenMarks) }
                else { onResult?(job.sentenceID, seenFrame, seenMarks) }
            }
        }
        let wanted = (job.start + job.end) / 2
        guard let frame = await frame(wanted), gen == generation else {
            liveLog.error("No frame for sentence [\(job.start, format: .fixed(precision: 1))–\(job.end, format: .fixed(precision: 1))]; skipped")
            return
        }
        saveFrame(frame, folder: context.folder)
        seenFrame = frame
        let began = ContinuousClock.now
        let clicks = job.clicks.filter { $0.displayID == frame.display.id }.map(\.point)
        let request = AnnotateRequest.make(model: model, frame: frame, sentence: job.text,
                                           recentSentences: job.recent, clicks: clicks, url: job.url)
        status = .working
        do {
            let response = try await Self.send(request, via: llm, timeout: timeout)
            guard gen == generation else { return }
            tokensUsed = tokensUsed + TokenUsage(input: response.usage?.input_tokens ?? 0,
                                                 output: response.usage?.output_tokens ?? 0)
            modelUsed = response.model ?? model
            guard let text = response.firstText() else { throw ClaudeError.noText }
            let marks = try AnnotateRequest.parse(text, frame: frame, createdAt: job.end)
            let elapsed = ContinuousClock.now - began
            liveLog.info("Sentence [\(job.start, format: .fixed(precision: 1))–\(job.end, format: .fixed(precision: 1))] frame t=\(frame.t, format: .fixed(precision: 1)) display \(frame.display.id): \(marks.count) mark(s) in \(elapsed, privacy: .public)")
            if marks.isEmpty { liveLog.info("No marks; model said: \(String(text.prefix(400)), privacy: .public)") }
            status = .ok
            seenMarks = marks
            guard !marks.isEmpty else { return }
            if job.speculative {
                onMarks?(marks)   // draw now; recorded when the final sentence adopts it
                return
            }
            context.emit(.aiAnnotation(sentenceID: job.sentenceID, annotations: marks, say: nil))
            onMarks?(marks)
        } catch {
            guard gen == generation else { return }
            liveLog.error("Live request failed: \(String(describing: error), privacy: .public)")
            status = .offline
        }
    }

    private func finishSpeculation(_ jobID: UUID, frame: LiveFrame?, marks: [Annotation]) {
        guard var spec = speculation, spec.jobID == jobID else { return }
        if let adopted = spec.adoptedBy {
            speculation = nil
            deliver(sentenceID: adopted.id, end: adopted.end, frame: frame, marks: marks)
        } else {
            spec.done = true
            spec.frame = frame
            spec.marks = marks
            speculation = spec
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
