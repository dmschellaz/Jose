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

    init(answer: String = #"{"marks":[{"shape":"rect","x":10,"y":10,"w":100,"h":50,"caption":"Save"}]}"#,
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
    var results: [(id: UUID, hadFrame: Bool, marks: Int)] = []
    var spoken: [String] = []
    /// Text of each question shown, nil when it closed.
    var questions: [String?] = []
}

/// `startedAgo` moves the session clock back, so test sentences at small times start "before" a question.
@MainActor private func makeAnnotator(_ llm: (any LLMClient)?, model: String = "claude-haiku-5-5",
                                      timeout: Duration = .seconds(8), mode: SessionMode = .live,
                                      questionTimeout: Duration = .seconds(20), startedAgo: Double = 0)
    async throws -> (LiveAnnotator, Sink) {
    let sink = Sink()
    let a = LiveAnnotator(llm: llm, model: model, frame: { liveTestFrame(t: $0) }, timeout: timeout,
                          questionTimeout: questionTimeout)
    a.onMarks = { sink.marks.append($0) }
    a.onStatus = { sink.statuses.append($0) }
    a.onResult = { id, frame, marks in sink.results.append((id, frame != nil, marks.count)) }
    a.onSpeak = { sink.spoken.append($0) }
    a.onQuestion = { sink.questions.append($0?.text) }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = try SessionFolder.create(root: root, slug: "live", date: Date())
    let ctx = SessionContext(folder: folder, clock: SessionClock(startedAt: Date().addingTimeInterval(-startedAgo)), mode: mode,
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

    @Test func everySentenceGetsOneResult() async throws {
        let llm = GatedLLM()
        let (a, sink) = try await makeAnnotator(llm, timeout: .milliseconds(200))
        let first = UUID(), second = UUID(), third = UUID()
        a.observe(.sentence(id: first, text: "first", start: 0, end: 1))
        await waitUntil { await llm.count == 1 }
        a.observe(.sentence(id: second, text: "second", start: 2, end: 3))
        a.observe(.sentence(id: third, text: "third", start: 4, end: 5))
        #expect(sink.results.map(\.id) == [second])          // replaced in the queue: skipped, no frame
        #expect(sink.results.first?.hadFrame == false)
        await llm.release(0)
        await waitUntil { sink.results.count == 2 }
        #expect(sink.results[1].id == first && sink.results[1].hadFrame && sink.results[1].marks == 1)
        await waitUntil { sink.results.count == 3 }       // third times out
        #expect(sink.results[2].id == third && sink.results[2].hadFrame && sink.results[2].marks == 0)
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

private let askAnswer = #"{"marks":[{"shape":"rect","x":10,"y":10,"w":100,"h":50,"caption":"Save"}],"say":"","question":{"text":"Which button?","options":["Save","Cancel"]}}"#
private let remarkAnswer = #"{"marks":[{"shape":"rect","x":10,"y":10,"w":100,"h":50,"caption":"Save"}],"say":"Now on billing.","question":{"text":"","options":[]}}"#

/// "via:answer" for each questionAnswered event, in order.
private func answers(_ events: [TimelineEvent]) -> [String] {
    events.compactMap { if case let .questionAnswered(_, answer, via, _) = $0 { "\(via.rawValue):\(answer)" } else { nil } }
}

@MainActor @Suite struct ChattyAnnotatorTests {
    @Test func questionOpensIsSpokenAndLogged() async throws {
        let llm = GatedLLM(answer: askAnswer, autoRelease: true)
        let (a, sink) = try await makeAnnotator(llm, mode: .chatty, startedAgo: 1000)
        let id = UUID()
        a.observe(.sentence(id: id, text: "make this bigger", start: 1, end: 2))
        await waitUntil { sink.questions.count == 1 }
        #expect(sink.questions == ["Which button?"])
        #expect(sink.spoken == ["Which button?"])
        #expect(a.openQuestion?.options == ["Save", "Cancel"])
        #expect(sink.events.contains { if case let .aiQuestion(_, sid, _, _, _) = $0 { sid == id } else { false } })
        guard case let .aiAnnotation(_, _, say)? = sink.events.first else { Issue.record("no aiAnnotation"); return }
        #expect(say == nil)
        let system = await llm.requests.first?.system
        #expect(system?.contains("Chatty mode is on") == true)
    }

    @Test func clickAnswerClosesTheQuestion() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: askAnswer, autoRelease: true), mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.questions.count == 1 }
        let q = try #require(a.openQuestion)
        a.answerQuestion(UUID(), "Save")   // stale id: ignored
        #expect(a.openQuestion != nil && answers(sink.events).isEmpty)
        a.answerQuestion(q.id, "Save")
        #expect(a.openQuestion == nil)
        #expect(sink.questions == ["Which button?", nil])
        #expect(answers(sink.events) == ["click:Save"])
        a.answerQuestion(q.id, "Cancel")   // nothing open: ignored
        #expect(answers(sink.events) == ["click:Save"])
    }

    @Test func skipClosesTheQuestion() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: askAnswer, autoRelease: true), mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.questions.count == 1 }
        let q = try #require(a.openQuestion)
        a.skipQuestion(q.id)
        #expect(a.openQuestion == nil)
        #expect(answers(sink.events) == ["skipped:"])
    }

    @Test func nextSentenceAnswersByVoiceAndIsSentWithTheQuestion() async throws {
        let llm = GatedLLM(answer: askAnswer, autoRelease: true)
        let (a, sink) = try await makeAnnotator(llm, mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.questions.count == 1 }
        a.observe(.sentence(id: UUID(), text: "the save one", start: 2000, end: 2001))
        #expect(answers(sink.events) == ["voice:the save one"])
        #expect(sink.questions.prefix(2) == ["Which button?", nil])
        await waitUntil { await llm.count == 2 }
        let second = try #require(await llm.sentence(1))
        #expect(second.contains("You asked: Which button?"))
        #expect(second.contains("Reviewer just said: the save one"))
    }

    @Test func onlyOneQuestionAtATime() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: askAnswer, autoRelease: true), mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.marks.count == 1 }
        a.observe(sentence("and that one", at: 3))   // started before the question: not an answer
        await waitUntil { sink.marks.count == 2 }
        #expect(sink.questions == ["Which button?"])
        #expect(sink.spoken == ["Which button?"])
        #expect(sink.events.filter { if case .aiQuestion = $0 { true } else { false } }.count == 1)
        #expect(answers(sink.events).isEmpty)
    }

    @Test func remarksAreRateLimitedAndLoggedWhenSpoken() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: remarkAnswer, autoRelease: true), mode: .chatty)
        a.observe(sentence("this page", at: 0))
        await waitUntil { sink.marks.count == 1 }
        a.observe(sentence("and this", at: 2))
        await waitUntil { sink.marks.count == 2 }
        #expect(sink.spoken == ["Now on billing."])
        let says = sink.events.compactMap { e -> String? in
            if case let .aiAnnotation(_, _, say) = e { say ?? "-" } else { nil }
        }
        #expect(says == ["Now on billing.", "-"])
    }

    @Test func unansweredQuestionIsSkippedAfterTheTimeout() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: askAnswer, autoRelease: true), mode: .chatty,
                                                questionTimeout: .milliseconds(50), startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.questions.count == 2 }
        #expect(sink.questions == ["Which button?", nil])
        #expect(answers(sink.events) == ["skipped:"])
        #expect(a.openQuestion == nil)
    }

    @Test func stopSkipsAnOpenQuestion() async throws {
        let (a, sink) = try await makeAnnotator(GatedLLM(answer: askAnswer, autoRelease: true), mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.questions.count == 1 }
        await a.stop()
        #expect(a.openQuestion == nil)
        #expect(sink.questions == ["Which button?", nil])
        #expect(answers(sink.events) == ["skipped:"])
    }

    @Test func liveModeNeverSpeaksOrAsks() async throws {
        let llm = GatedLLM(answer: askAnswer, autoRelease: true)
        let (a, sink) = try await makeAnnotator(llm, mode: .live)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { sink.marks.count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        #expect(sink.spoken.isEmpty && sink.questions.isEmpty && a.openQuestion == nil)
        #expect(!sink.events.contains { if case .aiQuestion = $0 { true } else { false } })
        let system = await llm.requests.first?.system
        #expect(system == AnnotateRequest.systemPrompt)
    }

    @Test func voiceAnswerSurvivesBeingReplacedInTheQueue() async throws {
        let llm = GatedLLM(answer: askAnswer)
        let (a, sink) = try await makeAnnotator(llm, mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { await llm.count == 1 }
        await llm.release(0)
        await waitUntil { sink.questions.count == 1 }
        a.observe(sentence("and that", at: 3))                       // B: in flight
        await waitUntil { await llm.count == 2 }
        a.observe(.sentence(id: UUID(), text: "the save one", start: 2000, end: 2001))   // C: answers, queued
        a.observe(.sentence(id: UUID(), text: "yes that", start: 2002, end: 2003))       // D replaces C
        await llm.release(1)
        await waitUntil { await llm.count == 3 }
        await llm.release(2)
        let d = try #require(await llm.sentence(2))
        #expect(d.contains("Reviewer just said: yes that"))
        #expect(d.contains("You asked: Which button?"))
    }

    @Test func staleResponseDoesNotOpenAQuestionWhenANewerSentenceIsQueued() async throws {
        let llm = GatedLLM(answer: askAnswer)
        let (a, sink) = try await makeAnnotator(llm, mode: .chatty, startedAgo: 1000)
        a.observe(sentence("make this bigger", at: 1))
        await waitUntil { await llm.count == 1 }
        a.observe(sentence("never mind, next", at: 3))   // queued behind the first
        await llm.release(0)
        await waitUntil { sink.marks.count == 1 }
        #expect(!sink.events.contains { if case .aiQuestion = $0 { true } else { false } })
        #expect(sink.questions.isEmpty && sink.spoken.isEmpty && a.openQuestion == nil)
    }
}
