import Testing
import Foundation
import CoreGraphics
@testable import RedlineCore

private let item = FeedbackItem(title: "Billing card padding is too tight", momentIDs: [1],
                                location: "/settings/billing, the Current plan card",
                                problem: "Text touches the card edge.", wanted: "More inner padding.",
                                quote: "this card feels really cramped", imageCaption: "red circle marks the card")

@Test func rendersGoldenMarkdown() {
    let ctx = ReportContext(appName: "localhost-3000", startURL: "http://localhost:3000/", startedAt: Date(timeIntervalSince1970: 1_763_821_800),
                            duration: 372, mode: .manual,
                            transcript: [TranscriptLine(t: 12, text: "this card feels really cramped"), TranscriptLine(t: 31, text: "(click)")],
                            imageFiles: [0: "01-billing-card-padding.png"], timeZone: .gmt)
    let expected = """
    # Feedback: localhost-3000 — 2025-11-22 14:30
    Reviewed at: http://localhost:3000/ · 6m 12s · mode: Manual

    ## 1. Billing card padding is too tight
    - **Where:** /settings/billing, the Current plan card
    - **Problem:** Text touches the card edge.
    - **Wanted:** More inner padding.
    - **You said:** "this card feels really cramped"
    - **Screenshot:** ![](01-billing-card-padding.png) — red circle marks the card

    ---
    ## Full transcript
    [00:12] this card feels really cramped
    [00:31] (click)

    """
    #expect(MarkdownRenderer.render(items: [item], context: ctx) == expected)
}

@Test func omitsEmptyFieldsAndHandlesNoItems() {
    var bare = item
    bare.wanted = ""
    bare.imageCaption = ""
    let ctx = ReportContext(appName: "session", startURL: nil, startedAt: Date(timeIntervalSince1970: 0), duration: 5,
                            mode: .manual, transcript: [], imageFiles: [:], timeZone: .gmt)
    let md = MarkdownRenderer.render(items: [bare], context: ctx)
    #expect(!md.contains("**Wanted:**"))
    #expect(!md.contains("**Screenshot:**"))
    #expect(md.contains("Reviewed at: unknown page · 0m 5s"))
    #expect(MarkdownRenderer.render(items: [], context: ctx).contains("_No feedback items were found in this session._"))
}

@Test func transcriptIncludesContextEvents() {
    let lines = TranscriptBuilder.lines([
        .sentence(id: UUID(), text: "hello", start: 1, end: 2),
        .click(point: .zero, displayID: 1, t: 3),
        .urlChanged(url: "http://localhost:3000/settings", title: nil, t: 4),
        .momentMarked(t: 5),
        .userMark(Annotation(shape: .rect(.zero), caption: nil, author: .user, createdAt: 6, displayID: 1)),
        .keyframe(KeyframeRef(id: UUID(), file: "k.png", t: 7, displayID: 1), reason: .periodic),
    ])
    #expect(lines.map(\.text) == ["hello", "(click)", "(opened /settings)", "(marked moment)", "(drew on screen)"])
}

@Test func fallbackItemsComeFromMoments() {
    var m = Moment(id: 1, start: 0, end: 2, sentences: [SentenceRef(id: UUID(), text: "fix this", start: 0, end: 2)])
    m.url = "http://localhost:3000/billing"
    let items = FallbackReport.items(from: [m])
    #expect(items == [FeedbackItem(title: "Moment 1", momentIDs: [1], location: "/billing",
                                   problem: "AI write-up unavailable. See the quote and screenshot.",
                                   wanted: "", quote: "fix this", imageCaption: "")])
}

@Test func feedbackItemUsesWireKeys() throws {
    let json = try JSONEncoder().encode(item)
    let dict = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    #expect(Set(dict.keys) == ["title", "moment_ids", "where", "problem", "wanted", "quote", "image_caption"])
}

@Test func handoffPromptPointsAtFeedbackFile() {
    let folder = SessionFolder(url: URL(fileURLWithPath: "/tmp/fb/myapp-2025-11-22-1430"))
    #expect(HandoffPrompt.make(folder: folder) ==
            "Read /tmp/fb/myapp-2025-11-22-1430/feedback.md and the screenshots it links, then make each revision in this project. Ask me if an item is ambiguous.")
}

@Test func timestampTreatsNonFiniteAsZero() {
    #expect(MarkdownRenderer.timestamp(.nan) == "00:00")
    #expect(MarkdownRenderer.timestamp(.infinity) == "00:00")
    #expect(MarkdownRenderer.timestamp(-.infinity) == "00:00")
    #expect(MarkdownRenderer.timestamp(75) == "01:15")
}

@Test func inlineHandoffNumbersAttachedImages() {
    let md = "# Feedback\n## 1. A\n- **Screenshot:** ![](01-a.png) — red oval\n## 2. B\n- **Screenshot:** ![](02-b.png)\n"
    #expect(HandoffPrompt.imageFiles(in: md) == ["01-a.png", "02-b.png"])
    let text = HandoffPrompt.inline(markdown: md)
    #expect(text.hasPrefix("Here is feedback I recorded on my app. I'm attaching 2 screenshots in order;"))
    #expect(text.contains("- **Screenshot:** attached image 1 (01-a.png) — red oval"))
    #expect(text.contains("attached image 2 (02-b.png)"))
    #expect(!text.contains("!["))
}

@Test func inlineHandoffWithoutImages() {
    let text = HandoffPrompt.inline(markdown: "# Feedback\n")
    #expect(HandoffPrompt.imageFiles(in: "# Feedback\n").isEmpty)
    #expect(text.contains("There are no screenshots."))
}
