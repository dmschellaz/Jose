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
    public let emit: @MainActor (TimelineEvent) -> Void

    public init(folder: SessionFolder, clock: SessionClock, emit: @escaping @MainActor (TimelineEvent) -> Void) {
        self.folder = folder
        self.clock = clock
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
        case done(ReportResult)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var lastFolder: SessionFolder?

    @ObservationIgnored private let capture: any FrameCapturing
    @ObservationIgnored private let services: [any SessionService]
    @ObservationIgnored private let outputRoot: @MainActor () -> URL
    @ObservationIgnored private let reportBuilder: @MainActor () -> any ReportBuilding
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private let clickDelay: Duration

    @ObservationIgnored private var events: [TimelineEvent] = []
    @ObservationIgnored private var metadata: SessionMetadata?
    @ObservationIgnored private var folder: SessionFolder?
    @ObservationIgnored private var clock: SessionClock?
    @ObservationIgnored private var started: [any SessionService] = []
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var accepting = false

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
        case .recording, .finalizing: return
        default: break
        }
        let date = now()
        let folder: SessionFolder
        do {
            folder = try SessionFolder.create(root: outputRoot(), slug: "session", date: date)
        } catch {
            state = .failed("Couldn't create the session folder: \(error.localizedDescription)")
            return
        }
        let clock = SessionClock(startedAt: date, now: now)
        self.folder = folder
        self.clock = clock
        events = []
        metadata = SessionMetadata(startedAt: date, endedAt: nil, mode: mode, displays: [], tokens: TokenUsage())
        accepting = true

        let context = SessionContext(folder: folder, clock: clock, emit: { [weak self] in self?.handle($0) })
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
            state = .failed(error.localizedDescription)
            return
        }

        state = .recording(mode: mode, startedAt: date)
        await keyframe(.periodic)
        persist()

        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.isRecording else { return }
                await self.keyframe(.periodic)
                self.persist()
            }
        }
    }

    public func handle(_ event: TimelineEvent) {
        guard accepting else { return }
        events.append(event)
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
        Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            await self?.keyframe(reason)
        }
    }

    public func markMoment() {
        guard isRecording, let clock else { return }
        handle(.momentMarked(t: clock.now()))
    }

    public func stop() async {
        guard isRecording, var folder, var metadata else { return }
        state = .finalizing
        tickTask?.cancel()
        tickTask = nil
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
        self.metadata = metadata
        persist()

        let result = await reportBuilder().build(document: document(), folder: folder)
        self.metadata?.tokens = result.tokens
        persist()
        lastFolder = folder
        reset()
        state = .done(result)
    }

    public func cancel() async {
        guard isRecording else { return }
        state = .finalizing
        tickTask?.cancel()
        tickTask = nil
        accepting = false
        await stopStarted()
        if let folder { try? FileManager.default.removeItem(at: folder.url) }
        reset()
        state = .idle
    }

    // MARK: - Private

    private func keyframe(_ reason: KeyframeReason) async {
        guard isRecording, let event = await capture.captureKeyframe(reason: reason), isRecording else { return }
        events.append(event)
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
        clock = nil
        metadata = nil
        events = []
    }
}
