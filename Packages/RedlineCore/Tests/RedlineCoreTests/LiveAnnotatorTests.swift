import Testing
import Foundation
import CoreGraphics
@testable import RedlineCore

/// Holds every request until the test releases it (or the caller is cancelled).
actor GatedLLM: LLMClient {
    private(set) var requests: [MessagesRequest] = []
    private var released: Set<Int> = []
    private let answer: String
    private let usage: (Int, Int)
    private let served: String?
    private let autoRelease: Bool

    init(answer: String = #"{"marks":[{"shape":"rect","x":10,"y":10,"w":100,"h":50,"x2":0,"y2":0,"caption":"Save"}]}"#,
         usage: (Int, Int) = (100, 10), served: String? = nil, autoRelease: Bool = false) {
        self.answer = answer
        self.usage = usage
        self.served = served
        self.autoRelease = autoRelease
    }

    func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        let index = requests.count
        requests.append(request)
        while !autoRelease && !released.contains(index) {
            try await Task.sleep(for: .milliseconds(2))
        }
        return MessagesResponse(content: [.init(type: "text", text: answer)], model: served, stop_reason: "end_turn",
                                usage: .init(input_tokens: usage.0, output_tokens: usage.1))
    }

    func release(_ index: Int) { released.insert(index) }
    var count: Int { requests.count }
    func sentence(_ index: Int) -> String? {
        requests[index].messages.first?.content.compactMap { if case let .text(s) = $0 { s } else { nil } }.joined()
    }
}

@MainActor private func waitUntil(_ condition: () async -> Bool) async {
    let start = Date()
    while !(await condition()) && Date().timeIntervalSince(start) < 2 { try? await Task.sleep(for: .milliseconds(5)) }
}

@MainActor private final class Sink {
    var events: [TimelineEvent] = []
    var marks: [[Annotation]] = []
    var statuses: [LiveStatus] = []
}

@MainActor private func makeAnnotator(_ llm: (any LLMClient)?, model: String = "claude-haiku-5-5",
                                      timeout: Duration = .seconds(8), mode: SessionMode = .live)
    async throws -> (LiveAnnotator, Sink) {
    let sink = Sink()
    let a = LiveAnnotator(llm: llm, model: model, frame: { liveTestFrame(t: $0) }, timeout: timeout)
    a.onMarks = { sink.marks.append($0) }
    a.onStatus = { sink.statuses.append($0) }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = try SessionFolder.create(root: root, slug: "live", date: Date())
    let ctx = SessionContext(folder: folder, clock: SessionClock(startedAt: Date()), mode: mode,
                             emit: { sink.events.append($0) })
    try await a.start(context: ctx)
    return (a, sink)
}

private func sentence(_ text: String, at t: Double) -> TimelineEvent {
    .sentence(id: UUID(), text: text, start: t, end: t + 1)
}

@MainActor @Suite struct LiveAnnotatorTests {
    @Test func sentenceProducesMarksAndEvent() async throws {
        let llm = GatedLLM(autoRelease: true)
        let (a, sink) = try await makeAnnotator(llm)
        a.observe(.urlChanged(url: "http://localhost:3000/cart", title: nil, t: 0))
        a.observe(.click(point: CGPoint(x: -500, y: 450), displayID: 7, t: 0.5))
        let id = UUID()
        a.observe(.sentence(id: id, text: "this one", start: 1, end: 2))
        await waitUntil { sink.marks.count == 1 }
        #expect(sink.marks.first?.first?.caption == "Save")
        #expect(sink.marks.first?.first?.createdAt == 2)
        guard case let .aiAnnotation(sid, annotations, say)? = sink.events.first else { Issue.record("no event"); return }
        #expect(sid == id && annotations.count == 1 && say == nil)
        #expect(a.status == .ok)
        #expect(sink.statuses == [.working, .ok])
        let text = try #require(await llm.sentence(0))
        #expect(text.contains("http://localhost:3000/cart") && text.contains("(640, 320)"))
    }

    @Test func oneInFlightAndNewestWins() async throws {
        let llm = GatedLLM()
        let (a, sink) = try await makeAnnotator(llm)
        a.observe(sentence("first", at: 0))
        await waitUntil { await llm.count == 1 }
        a.observe(sentence("second", at: 2))
        a.observe(sentence("third", at: 4))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await llm.count == 1)
        await llm.release(0)
        await waitUntil { await llm.count == 2 }
        #expect(sink.marks.count == 1)   // the first result is still drawn
        await llm.release(1)
        await waitUntil { sink.marks.count == 2 }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await llm.count == 2)
        #expect(try #require(await llm.sentence(0)).contains("Reviewer just said: first"))
        let last = try #require(await llm.sentence(1))
        #expect(last.contains("Reviewer just said: third"))
        #expect(last.contains("- first") && last.contains("- second"))   // skipped sentences still give context
    }

    @Test func timeoutGoesOfflineAndEmitsNothing() async throws {
        let llm = GatedLLM()
        let (a, sink) = try await makeAnnotator(llm, timeout: .milliseconds(30))
        a.observe(sentence("hello", at: 0))
        await waitUntil { a.status == .offline }
        #expect(a.status == .offline)
        #expect(sink.events.isEmpty && sink.marks.isEmpty)
        #expect(a.tokensUsed == TokenUsage())
        // The next sentence is still sent.
        a.observe(sentence("again", at: 2))
        await waitUntil { await llm.count == 2 }
        #expect(await llm.count == 2)
    }

    @Test func malformedAnswerGoesOffline() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: "nope", autoRelease: true))
        a.observe(sentence("hello", at: 0))
        await waitUntil { a.status == .offline }
        #expect(a.status == .offline && sink.events.isEmpty)
    }

    @Test func manualModeSendsNothing() async throws {
        let llm = GatedLLM(autoRelease: true)
        let (a, sink) = try await makeAnnotator(llm, mode: .manual)
        a.observe(sentence("hello", at: 0))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await llm.count == 0)
        #expect(sink.statuses.isEmpty)
    }

    @Test func noClientSendsNothing() async throws {
        let (a, sink) = try await makeAnnotator(nil)
        a.observe(sentence("hello", at: 0))
        try await Task.sleep(for: .milliseconds(20))
        #expect(sink.statuses.isEmpty && a.tokensUsed == TokenUsage())
    }

    @Test func tokensAccumulateAndModelIsReported() async throws {
        let llm = GatedLLM(usage: (100, 10), served: "claude-haiku-5-5-20261101", autoRelease: true)
        let (a, sink) = try await makeAnnotator(llm)
        #expect(a.modelUsed == nil)
        a.observe(sentence("one", at: 0))
        await waitUntil { sink.marks.count == 1 }
        a.observe(sentence("two", at: 2))
        await waitUntil { sink.marks.count == 2 }
        #expect(a.tokensUsed == TokenUsage(input: 200, output: 20))
        #expect(a.modelUsed == "claude-haiku-5-5-20261101")
        await a.stop()
        #expect(a.tokensUsed == TokenUsage(input: 200, output: 20))   // still readable after stop
    }

    @Test func modelFallsBackToRequested() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(autoRelease: true), model: "claude-sonnet-5-5")
        a.observe(sentence("one", at: 0))
        await waitUntil { sink.marks.count == 1 }
        #expect(a.modelUsed == "claude-sonnet-5-5")
    }

    @Test func stopDropsLateResults() async throws {
        let llm = GatedLLM()
        let (a, sink) = try await makeAnnotator(llm)
        a.observe(sentence("one", at: 0))
        await waitUntil { await llm.count == 1 }
        a.observe(sentence("two", at: 2))
        await a.stop()
        #expect(a.status == .idle)
        await llm.release(0)
        await llm.release(1)
        try await Task.sleep(for: .milliseconds(40))
        #expect(sink.marks.isEmpty && sink.events.isEmpty)
        #expect(await llm.count == 1)
        a.observe(sentence("after stop", at: 5))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await llm.count == 1)
    }
}
