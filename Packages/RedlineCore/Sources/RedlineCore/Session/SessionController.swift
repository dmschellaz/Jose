import Foundation
import Observation

public struct SessionClock: Sendable {
    public let startedAt: Date
    private let nowFn: @Sendable () -> Date

    public init(startedAt: Date, now: @escaping @Sendable () -> Date = Date.init) {
        self.startedAt = startedAt
        self.nowFn = now
    }

    /// Seconds since session start.
    public func now() -> Double { nowFn().timeIntervalSince(startedAt) }
}

public struct SessionContext {
    public let folder: SessionFolder
    public let clock: SessionClock
    public let mode: SessionMode
    public let emit: @MainActor (TimelineEvent) -> Void

    public init(folder: SessionFolder, clock: SessionClock, mode: SessionMode = .manual,
                emit: @escaping @MainActor (TimelineEvent) -> Void) {
        self.folder = folder
        self.clock = clock
        self.mode = mode
        self.emit = emit
    }
}

@MainActor public protocol SessionService: AnyObject {
    func start(context: SessionContext) async throws
    func stop() async
}

@MainActor public protocol FrameCapturing: SessionService {
    var displays: [DisplayGeometry] { get }
    func captureKeyframe(reason: KeyframeReason) async -> TimelineEvent?
}

@MainActor @Observable
public final class SessionController {
    public enum State: Equatable, Sendable {
        case idle
        case recording(mode: SessionMode, startedAt: Date)
        case finalizing
        /// Recording has stopped and the session is saved; the report waits for `writeReport(including:)`.
        /// Only used when `holdReportForReview` is on.
        case reviewing
        case done(ReportResult)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var lastFolder: SessionFolder?
    /// Folder of the session in progress (follows the rename in `stop`); nil when idle.
    public private(set) var currentFolder: SessionFolder?

    @ObservationIgnored private let capture: any FrameCapturing
    @ObservationIgnored private let services: [any SessionService]
    @ObservationIgnored private let outputRoot: @MainActor () -> URL
    @ObservationIgnored private let reportBuilder: @MainActor () -> any ReportBuilding
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private let clickDelay: Duration
    /// When true, `stop()` ends in `.reviewing` instead of writing the report straight away.
    @ObservationIgnored public var holdReportForReview = false
    @ObservationIgnored private var liveUsage: (tokens: TokenUsage, model: String?) = (TokenUsage(), nil)

    @ObservationIgnored private var events: [TimelineEvent] = []
    @ObservationIgnored private var metadata: SessionMetadata?
    @ObservationIgnored private var folder: SessionFolder?
    @ObservationIgnored private var clock: SessionClock?
    @ObservationIgnored private var started: [any SessionService] = []
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var accepting = false
    /// True while `start` awaits service startup (state is not yet `.recording`).
    @ObservationIgnored private var starting = false
    /// Set by `cancel` during startup; honoured when startup finishes.
    @ObservationIgnored private var pendingCancel = false
    /// Identifies the current session; bumped whenever a session begins or ends so stale async work can detect it.
    @ObservationIgnored private var generation = 0

    public init(capture: any FrameCapturing, services: [any SessionService],
                outputRoot: @escaping @MainActor () -> URL,
                reportBuilder: @escaping @MainActor () -> any ReportBuilding,
                now: @escaping @Sendable () -> Date = Date.init,
                tickInterval: Duration = .seconds(5), clickDelay: Duration = .milliseconds(300)) {
        self.capture = capture
        self.services = services
        self.outputRoot = outputRoot
        self.reportBuilder = reportBuilder
        self.now = now
        self.tickInterval = tickInterval
        self.clickDelay = clickDelay
    }

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    public func start(mode: SessionMode) async {
        switch state {
        case .recording, .finalizing, .reviewing: return
        default: break
        }
        guard !starting else { return }
        starting = true
        pendingCancel = false
        generation += 1
        let gen = generation
        let date = now()
        let folder: SessionFolder
        do {
            folder = try SessionFolder.create(root: outputRoot(), slug: "session", date: date)
        } catch {
            starting = false
            pendingCancel = false
            state = .failed("Couldn't create the session folder: \(error.localizedDescription)")
            return
        }
        let clock = SessionClock(startedAt: date, now: now)
        self.folder = folder
        self.currentFolder = folder
        self.clock = clock
        events = []
        metadata = SessionMetadata(startedAt: date, endedAt: nil, mode: mode, displays: [], tokens: TokenUsage())
        accepting = true

        let context = SessionContext(folder: folder, clock: clock, mode: mode, emit: { [weak self] in self?.handle($0) })
        do {
            for service in [capture as any SessionService] + services {
                try await service.start(context: context)
                started.append(service)
            }
        } catch {
            accepting = false
            await stopStarted()
            try? FileManager.default.removeItem(at: folder.url)
            reset()
            starting = false
            if pendingCancel {
                pendingCancel = false
                state = .idle
            } else {
                state = .failed(error.localizedDescription)
            }
            return
        }

        starting = false
        if pendingCancel {
            pendingCancel = false
            accepting = false
            await stopStarted()
            try? FileManager.default.removeItem(at: folder.url)
            reset()
            state = .idle
            return
        }

        metadata?.displays = capture.displays
        state = .recording(mode: mode, startedAt: date)
        await keyframe(.periodic, gen: gen)
        guard gen == generation, isRecording else { return }
        persist()

        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self, self.generation == gen, self.isRecording else { return }
                await self.keyframe(.periodic, gen: gen)
                guard self.generation == gen, self.isRecording else { return }
                self.metadata?.displays = self.capture.displays
                self.persist()
            }
        }
    }

    public func handle(_ event: TimelineEvent) {
        guard accepting else { return }
        events.append(event)
        for service in started {
            (service as? any TimelineObserving)?.observe(event)
        }
        guard isRecording else { return }

        let reason: KeyframeReason
        var delay: Duration = .zero
        switch event {
        case .click: reason = .click; delay = clickDelay
        case .sentence: reason = .sentence
        case .userMark: reason = .pen
        case .momentMarked: reason = .mark
        default: return
        }
        let gen = generation
        Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            await self?.keyframe(reason, gen: gen)
        }
    }

    public func markMoment() {
        guard isRecording, let clock else { return }
        handle(.momentMarked(t: clock.now()))
    }

    public func stop() async {
        guard isRecording, var folder, var metadata else { return }
        state = .finalizing
        generation += 1
        tickTask?.cancel()
        tickTask = nil
        let reporters = started.compactMap { $0 as? any TokenReporting }
        await stopStarted()   // services may still emit final events here
        accepting = false

        metadata.endedAt = now()
        metadata.displays = capture.displays
        let firstURL = events.lazy.compactMap { e -> String? in
            guard case let .urlChanged(url, _, _) = e else { return nil }
            return url
        }.first
        if let renamed = try? folder.renamed(slug: SessionFolder.slug(fromURL: firstURL), date: metadata.startedAt) {
            folder = renamed
        }
        self.folder = folder
        self.currentFolder = folder
        self.metadata = metadata
        liveUsage = (reporters.reduce(TokenUsage()) { $0 + $1.tokensUsed }, reporters.lazy.compactMap(\.modelUsed).first)
        self.metadata?.tokens = liveUsage.tokens
        persist()
        lastFolder = folder

        if holdReportForReview {
            state = .reviewing
            return
        }
        await writeReport(including: nil)
    }

    /// Writes the report for a stopped session. `including` limits it to those sentences (and the AI marks
    /// made for them); nil means all. session.json always keeps the full timeline.
    public func writeReport(including sentenceIDs: Set<UUID>?) async {
        guard state == .reviewing || state == .finalizing, let folder, metadata != nil else { return }
        state = .finalizing
        var doc = document()
        if let ids = sentenceIDs {
            // A question goes with the sentence it asked about; its answer goes with the question.
            let keptQuestions = Set(doc.events.compactMap { e -> UUID? in
                guard case let .aiQuestion(qid, sid, _, _, _) = e, ids.contains(sid) else { return nil }
                return qid
            })
            let keptSentenceEnds = Set(doc.events.compactMap { e -> Double? in
                guard case let .sentence(id, _, _, end) = e, ids.contains(id) else { return nil }
                return end
            })
            doc.events = doc.events.filter { e in
                switch e {
                case let .sentence(id, _, _, _): return ids.contains(id)
                case let .aiAnnotation(id, _, _): return ids.contains(id)
                case let .aiQuestion(_, sid, _, _, _): return ids.contains(sid)
                case let .questionAnswered(qid, _, via, t):
                    guard keptQuestions.contains(qid) else { return false }
                    // A spoken answer is a sentence's words: it goes only if that sentence (stamped at its end) is kept.
                    return via != .voice || keptSentenceEnds.contains(t)
                default: return true
                }
            }
        }
        var result = await reportBuilder().build(document: doc, folder: folder)
        result.liveTokens = liveUsage.tokens
        result.liveModel = liveUsage.model
        self.metadata?.tokens = result.tokens + result.liveTokens
        persist()
        reset()
        state = .done(result)
    }

    /// Leaves review without writing a report. The session stays on disk; "Regenerate" can still report it.
    public func endReview() {
        guard state == .reviewing else { return }
        reset()
        state = .idle
    }

    public func cancel() async {
        if starting {
            pendingCancel = true
            accepting = false
            return
        }
        guard isRecording else { return }
        state = .finalizing
        generation += 1
        tickTask?.cancel()
        tickTask = nil
        accepting = false
        await stopStarted()
        if let folder { try? FileManager.default.removeItem(at: folder.url) }
        reset()
        state = .idle
    }

    // MARK: - Private

    private func keyframe(_ reason: KeyframeReason, gen: Int) async {
        guard gen == generation, isRecording,
              let event = await capture.captureKeyframe(reason: reason),
              gen == generation, isRecording else { return }
        events.append(event)
        for service in started { (service as? any TimelineObserving)?.observe(event) }
    }

    private func stopStarted() async {
        for service in started.reversed() { await service.stop() }
        started = []
    }

    /// Only call while `metadata` is set (between start and reset).
    private func document() -> SessionDocument {
        SessionDocument(metadata: metadata!, events: events.sorted { $0.time < $1.time })
    }

    private func persist() {
        guard let folder, metadata != nil else { return }
        try? SessionStore.save(document(), to: folder)
    }

    private func reset() {
        folder = nil
        currentFolder = nil
        clock = nil
        metadata = nil
        events = []
    }
}
