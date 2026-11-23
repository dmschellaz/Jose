import Testing
import Foundation
import CoreGraphics
@testable import RedlineCore

private func ai(_ caption: String?) -> Annotation {
    Annotation(shape: .rect(.zero), caption: caption, author: .ai, createdAt: 1, displayID: 1)
}

private func headers(_ request: MessagesRequest) -> [String] {
    request.messages[0].content.compactMap { block in
        guard case let .text(t) = block, t.hasPrefix("Moment ") else { return nil }
        return String(t.split(separator: "\n")[0])
    }
}

@Test func momentHeaderListsLiveAIMarks() {
    var m = Moment(id: 1, start: 0, end: 2, sentences: [SentenceRef(id: UUID(), text: "too cramped", start: 0, end: 2)])
    m.url = "http://localhost:3000/billing"
    m.userMarks = [Annotation(shape: .stroke([.zero]), caption: nil, author: .user, createdAt: 1, displayID: 1)]
    m.aiMarks = [ai("Billing card"), ai("Save button")]
    var plain = Moment(id: 2, start: 5, end: 6, sentences: [])
    plain.url = "http://localhost:3000/"
    let req = ReportRequest.make(model: "m", input: ReportInput(moments: [m, plain], images: [:], transcript: [], startURL: nil))
    #expect(headers(req) == [
        "Moment 1 [00:00–00:02] on http://localhost:3000/billing (reviewer drew 1 mark(s)) (live AI marked: \"Billing card\", \"Save button\")",
        "Moment 2 [00:05–00:06] on http://localhost:3000/",
    ])
}

@Test func aiMarksNoteCountsUnlabeledMarks() {
    #expect(ReportRequest.aiMarksNote([]) == "")
    #expect(ReportRequest.aiMarksNote([ai(nil), ai("  ")]) == " (live AI marked: 2 unlabeled mark(s))")
    #expect(ReportRequest.aiMarksNote([ai("Card"), ai(nil)]) == " (live AI marked: \"Card\", 1 unlabeled mark(s))")
}

@Test func systemPromptExplainsBothMarkColours() {
    let p = ReportRequest.systemPrompt
    #expect(p.contains("Red marks on a screenshot are the reviewer's own"))
    #expect(p.contains("Blue marks with short labels are a live AI's guesses"))
    #expect(p.contains("trust the reviewer's words and red marks over them"))
    #expect(p.contains("image_caption: what the marks on the screenshot show, naming the colour"))
}

@Test func schemaIsUnchanged() throws {
    let data = try JSONEncoder().encode(ReportRequest.schema)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let items = try #require((root["properties"] as? [String: Any])?["items"] as? [String: Any])
    let item = try #require(items["items"] as? [String: Any])
    #expect(Set(item["required"] as? [String] ?? []) == ["title", "moment_ids", "where", "problem", "wanted", "quote", "image_caption"])
}
