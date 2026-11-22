import Testing
import Foundation
import CoreGraphics
@testable import RedlineCore

@MainActor final class FakeCapture: FrameCapturing {
    var displays = [DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 2)]
    var reasons: [KeyframeReason] = []
    var started = false, stopped = false
    func start(context: SessionContext) async throws { started = true }
    func stop() async { stopped = true }
    func captureKeyframe(reason: KeyframeReason) async -> TimelineEvent? {
        reasons.append(reason)
        return .keyframe(KeyframeRef(id: UUID(), file: "k\(reasons.count).png", t: Double(reasons.count), displayID: 1), reason: reason)
    }
}

@MainActor final class FakeService: SessionService {
    var fail = false
    var context: SessionContext?
    var stopped = false
    var emitOnStop: TimelineEvent?
    func start(context: SessionContext) async throws {
        if fail { throw CocoaError(.featureUnsupported) }
        self.context = context
    }
    func stop() async {
        if let e = emitOnStop { context?.emit(e) }
        stopped = true
    }
}

final class FakeBuilder: ReportBuilding, @unchecked Sendable {
    var document: SessionDocument?
    var folder: SessionFolder?
    func build(document: SessionDocument, folder: SessionFolder) async -> ReportResult {
        self.document = document
        self.folder = folder
        return ReportResult(itemCount: 1, usedAI: false, prompt: "Read it", error: nil, tokens: TokenUsage(input: 5, output: 1))
    }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async {
    let start = Date()
    while !condition() && Date().timeIntervalSince(start) < 2 { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor private func makeController(service: FakeService = FakeService(), capture: FakeCapture = FakeCapture(),
                                       builder: FakeBuilder = FakeBuilder(), tick: Duration = .seconds(3600)) -> (SessionController, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let c = SessionController(capture: capture, services: [service], outputRoot: { root }, reportBuilder: { builder },
                              now: { Date(timeIntervalSince1970: 1_763_821_800) }, tickInterval: tick, clickDelay: .zero)
    return (c, root)
}

@MainActor @Suite struct SessionControllerTests {
    @Test func startRecordsAndTakesInitialKeyframe() async {
        let capture = FakeCapture(), service = FakeService()
        let (c, _) = makeController(service: service, capture: capture)
        await c.start(mode: .manual)
        #expect(c.isRecording)
        #expect(capture.started && service.context != nil)
        #expect(capture.reasons == [.periodic])
        #expect(FileManager.default.fileExists(atPath: service.context!.folder.documentURL.path))
    }

    @Test func eventsTriggerKeyframes() async {
        let capture = FakeCapture(), service = FakeService()
        let (c, _) = makeController(service: service, capture: capture)
        await c.start(mode: .manual)
        c.handle(.click(point: .zero, displayID: 1, t: 1))
        c.handle(.sentence(id: UUID(), text: "hi", start: 1, end: 2))
        c.markMoment()
        await waitUntil { capture.reasons.count == 4 }
        #expect(Set(capture.reasons) == [.periodic, .click, .sentence, .mark])
    }

    @Test func stopBuildsReportKeepsLateSentencesAndRenames() async throws {
        let capture = FakeCapture(), service = FakeService(), builder = FakeBuilder()
        service.emitOnStop = .sentence(id: UUID(), text: "last words", start: 5, end: 6)
        let (c, _) = makeController(service: service, capture: capture, builder: builder)
        await c.start(mode: .manual)
        c.handle(.urlChanged(url: "http://localhost:3000/", title: nil, t: 0.5))
        await c.stop()
        #expect(c.state == .done(ReportResult(itemCount: 1, usedAI: false, prompt: "Read it", error: nil, tokens: TokenUsage(input: 5, output: 1))))
        #expect(service.stopped && capture.stopped)
        let doc = try #require(builder.document)
        #expect(doc.events.contains { if case .sentence(_, "last words", _, _) = $0 { true } else { false } })
        #expect(doc.metadata.displays.count == 1)
        #expect(builder.folder?.url.lastPathComponent.hasPrefix("localhost-3000-") == true)
        let saved = try SessionStore.load(from: try #require(c.lastFolder))
        #expect(saved.metadata.tokens == TokenUsage(input: 5, output: 1))
    }

    @Test func failedStartCleansUp() async {
        let capture = FakeCapture(), service = FakeService()
        service.fail = true
        let (c, root) = makeController(service: service, capture: capture)
        await c.start(mode: .manual)
        guard case .failed = c.state else { Issue.record("expected failed, got \(c.state)"); return }
        #expect(capture.stopped)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(contents.isEmpty)
    }

    @Test func cancelDeletesFolder() async {
        let service = FakeService()
        let (c, _) = makeController(service: service)
        await c.start(mode: .manual)
        let folder = service.context!.folder
        await c.cancel()
        #expect(c.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: folder.url.path))
    }

    @Test func periodicTickCapturesAndSaves() async {
        let capture = FakeCapture()
        let (c, _) = makeController(capture: capture, tick: .milliseconds(20))
        await c.start(mode: .manual)
        await waitUntil { capture.reasons.count >= 3 }
        #expect(capture.reasons.count >= 3)
        await c.cancel()
    }
}

@MainActor final class GatedService: SessionService {
    var startCount = 0, stopped = false
    var waiting = false
    private var cont: CheckedContinuation<Void, Never>?
    func start(context: SessionContext) async throws {
        startCount += 1
        waiting = true
        await withCheckedContinuation { cont = $0 }
        waiting = false
    }
    func stop() async { stopped = true }
    func release() { cont?.resume(); cont = nil }
}

@MainActor final class GatedCapture: FrameCapturing {
    var displays: [DisplayGeometry] = []
    var hold = false
    var held = false
    var stopped = false
    private var cont: CheckedContinuation<Void, Never>?
    func start(context: SessionContext) async throws {}
    func stop() async { stopped = true }
    func captureKeyframe(reason: KeyframeReason) async -> TimelineEvent? {
        if hold {
            hold = false
            held = true
            await withCheckedContinuation { cont = $0 }
            held = false
        }
        return .keyframe(KeyframeRef(id: UUID(), file: "\(reason).png", t: 1, displayID: 1), reason: reason)
    }
    func release() { cont?.resume(); cont = nil }
}

@MainActor @Suite struct SessionControllerOverlapTests {
    private func make(service: GatedService, capture: any FrameCapturing, builder: FakeBuilder = FakeBuilder()) -> (SessionController, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let c = SessionController(capture: capture, services: [service], outputRoot: { root }, reportBuilder: { builder },
                                  now: { Date(timeIntervalSince1970: 1_763_821_800) }, tickInterval: .seconds(3600), clickDelay: .zero)
        return (c, root)
    }

    @Test func secondStartWhileStartingIsIgnored() async {
        let service = GatedService()
        let (c, root) = make(service: service, capture: GatedCapture())
        let first = Task { await c.start(mode: .manual) }
        await waitUntil { service.waiting }
        await c.start(mode: .manual)
        #expect(service.startCount == 1)
        service.release()
        await first.value
        #expect(c.isRecording)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(contents.count == 1)
        await c.cancel()
    }

    @Test func cancelDuringStartLeavesIdle() async {
        let service = GatedService(), capture = GatedCapture()
        let (c, root) = make(service: service, capture: capture)
        let first = Task { await c.start(mode: .manual) }
        await waitUntil { service.waiting }
        await c.cancel()
        service.release()
        await first.value
        #expect(c.state == .idle)
        #expect(service.stopped && capture.stopped)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        #expect(contents.isEmpty)
    }

    @Test func staleKeyframeFromCancelledSessionIsDropped() async throws {
        let service = GatedService(), capture = GatedCapture(), builder = FakeBuilder()
        let (c, _) = make(service: service, capture: capture, builder: builder)
        let first = Task { await c.start(mode: .manual) }
        await waitUntil { service.waiting }
        service.release()
        await first.value
        capture.hold = true
        c.markMoment()
        await waitUntil { capture.held }
        await c.cancel()
        let second = Task { await c.start(mode: .manual) }
        await waitUntil { service.waiting }
        service.release()
        await second.value
        capture.release()
        try? await Task.sleep(for: .milliseconds(50))
        await c.stop()
        let doc = try #require(builder.document)
        #expect(!doc.events.contains { if case .keyframe(_, .mark) = $0 { true } else { false } })
    }
}
