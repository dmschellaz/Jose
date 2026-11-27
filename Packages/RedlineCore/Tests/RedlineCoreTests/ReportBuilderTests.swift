import Testing
import Foundation
import CoreGraphics
@testable import RedlineCore

private struct FakeLLM: LLMClient {
    var text: String?
    var error: ClaudeError?
    func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        if let error { throw error }
        let body: [String: Any] = [
            "content": [["type": "text", "text": text ?? ""]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 100, "output_tokens": 20],
        ]
        return try JSONDecoder().decode(MessagesResponse.self, from: JSONSerialization.data(withJSONObject: body))
    }
}

private func makeSession() throws -> (SessionDocument, SessionFolder) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = try SessionFolder.create(root: root, slug: "localhost-3000", date: Date(timeIntervalSince1970: 1_763_821_800), timeZone: .gmt)
    let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    try ImageFiles.writePNG(ctx.makeImage()!, to: folder.rawURL.appending(path: "k1.png"))
    let mark = Annotation(shape: .rect(CGRect(x: 10, y: 10, width: 20, height: 20)), caption: nil, author: .user, createdAt: 2, displayID: 1)
    let doc = SessionDocument(
        metadata: SessionMetadata(startedAt: Date(timeIntervalSince1970: 1_763_821_800), endedAt: Date(timeIntervalSince1970: 1_763_821_830),
                                  mode: .manual, displays: [DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 50), scale: 2)],
                                  tokens: TokenUsage()),
        events: [
            .urlChanged(url: "http://localhost:3000/billing", title: nil, t: 0),
            .sentence(id: UUID(), text: "this card is too cramped", start: 1, end: 3),
            .userMark(mark),
            .keyframe(KeyframeRef(id: UUID(), file: "k1.png", t: 2.1, displayID: 1), reason: .pen),
        ])
    return (doc, folder)
}

@Test func buildsAIReport() async throws {
    let (doc, folder) = try makeSession()
    let llm = FakeLLM(text: #"{"items":[{"title":"Loosen billing card padding","moment_ids":[1],"where":"/billing","problem":"cramped","wanted":"more padding","quote":"this card is too cramped","image_caption":"red box marks the card"}]}"#)
    let result = await ReportBuilder(llm: llm, model: "claude-sonnet-5-5", timeZone: .gmt).build(document: doc, folder: folder)
    #expect(result.usedAI && result.itemCount == 1 && result.error == nil)
    #expect(result.tokens == TokenUsage(input: 100, output: 20))
    #expect(result.model == "claude-sonnet-5-5")   // response has no model field, so the requested one is used
    let md = try String(contentsOf: folder.feedbackURL, encoding: .utf8)
    #expect(md.contains("## 1. Loosen billing card padding"))
    #expect(md.contains("![](01-loosen-billing-card.png)"))
    #expect(FileManager.default.fileExists(atPath: folder.url.appending(path: "01-loosen-billing-card.png").path))
    #expect(result.prompt.contains("feedback.md"))
}

@Test func fallsBackWithoutKey() async throws {
    let (doc, folder) = try makeSession()
    let result = await ReportBuilder(llm: nil, model: "claude-sonnet-5-5", timeZone: .gmt).build(document: doc, folder: folder)
    #expect(!result.usedAI && result.error == "No API key set")
    let md = try String(contentsOf: folder.feedbackURL, encoding: .utf8)
    #expect(md.contains("## 1. Moment 1"))
    #expect(md.contains("![](01-moment-1.png)"))
}

@Test func fallsBackOnAPIError() async throws {
    let (doc, folder) = try makeSession()
    let result = await ReportBuilder(llm: FakeLLM(error: .http(status: 500, body: "boom")), model: "m", timeZone: .gmt)
        .build(document: doc, folder: folder)
    #expect(!result.usedAI)
    #expect(result.error?.contains("500") == true)
    #expect(result.itemCount == 1)
}

@Test func crashedSessionUsesLatestEventTimeForDuration() async throws {
    var (doc, folder) = try makeSession()
    doc.metadata.endedAt = nil
    doc.events.append(.urlChanged(url: "http://localhost:3000/late", title: nil, t: 95))
    _ = await ReportBuilder(llm: nil, model: "m", timeZone: .gmt).build(document: doc, folder: folder)
    let md = try String(contentsOf: folder.feedbackURL, encoding: .utf8)
    #expect(md.contains("1m 35s"))
}

@Test func noMomentsWithLLMReportsReason() async throws {
    var (doc, folder) = try makeSession()
    doc.events = []
    let result = await ReportBuilder(llm: FakeLLM(text: "{}"), model: "m", timeZone: .gmt).build(document: doc, folder: folder)
    #expect(!result.usedAI)
    #expect(result.error == "Nothing was said or marked in this session.")
}

@Test func answeredQuestionsReachFeedbackMarkdown() async throws {
    var (doc, folder) = try makeSession()
    let q = UUID(), skipped = UUID()
    doc.events += [
        .aiQuestion(id: q, sentenceID: UUID(), text: "Which card?", options: ["Billing card", "Plan card"], t: 2.5),
        .questionAnswered(id: q, answer: "Billing card", via: .voice, t: 4),
        .aiQuestion(id: skipped, sentenceID: UUID(), text: "Smaller font too?", options: ["Yes", "No"], t: 4.5),
        .questionAnswered(id: skipped, answer: "", via: .skipped, t: 25),
    ]
    // Fallback report (no key): still one Clarified line, for the answered question only.
    _ = await ReportBuilder(llm: nil, model: "m", timeZone: .gmt).build(document: doc, folder: folder)
    let fallback = try String(contentsOf: folder.feedbackURL, encoding: .utf8)
    #expect(fallback.contains("- **Clarified:** Which card? → Billing card\n"))
    #expect(fallback.components(separatedBy: "**Clarified:**").count == 2)

    // AI report: the item that lists moment 1 gets the same line.
    let llm = FakeLLM(text: #"{"items":[{"title":"Loosen billing card padding","moment_ids":[1],"where":"/billing","problem":"cramped","wanted":"more padding","quote":"this card is too cramped","image_caption":""}]}"#)
    _ = await ReportBuilder(llm: llm, model: "claude-sonnet-5-5", timeZone: .gmt).build(document: doc, folder: folder)
    let ai = try String(contentsOf: folder.feedbackURL, encoding: .utf8)
    #expect(ai.contains("## 1. Loosen billing card padding"))
    #expect(ai.contains("- **Clarified:** Which card? → Billing card\n"))
}
