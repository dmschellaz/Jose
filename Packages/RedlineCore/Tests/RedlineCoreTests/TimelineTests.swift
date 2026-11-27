import Testing
import Foundation
import CoreGraphics
@testable import RedlineCore

@Test func eventTimes() {
    let mark = Annotation(shape: .rect(.zero), caption: nil, author: .user, createdAt: 7, displayID: 1)
    #expect(TimelineEvent.sentence(id: UUID(), text: "hi", start: 1, end: 2).time == 1)
    #expect(TimelineEvent.click(point: .zero, displayID: 1, t: 3).time == 3)
    #expect(TimelineEvent.userMark(mark).time == 7)
    #expect(TimelineEvent.aiAnnotation(sentenceID: UUID(), annotations: [mark], say: nil).time == 7)
    #expect(TimelineEvent.keyframe(KeyframeRef(id: UUID(), file: "a.png", t: 9, displayID: 1), reason: .click).time == 9)
}

@Test func documentRoundTripsThroughDisk() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = try SessionFolder.create(root: dir, slug: "test", date: Date(timeIntervalSince1970: 1_700_000_000), timeZone: .gmt)
    let doc = SessionDocument(
        metadata: SessionMetadata(startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil, mode: .manual,
                                  displays: [DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10), scale: 2)],
                                  tokens: TokenUsage()),
        events: [.urlChanged(url: "http://localhost:3000/", title: "Home", t: 0.5), .momentMarked(t: 2)])
    try SessionStore.save(doc, to: folder)
    #expect(try SessionStore.load(from: folder) == doc)
}

@Test func questionEventTimes() {
    #expect(TimelineEvent.aiQuestion(id: UUID(), sentenceID: UUID(), text: "Which card?", options: ["Billing", "Profile"], t: 4).time == 4)
    #expect(TimelineEvent.questionAnswered(id: UUID(), answer: "Billing", via: .click, t: 6).time == 6)
}

@Test func questionEventsRoundTripThroughDisk() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = try SessionFolder.create(root: dir, slug: "chatty", date: Date(timeIntervalSince1970: 1_700_000_000), timeZone: .gmt)
    let q = UUID()
    let doc = SessionDocument(
        metadata: SessionMetadata(startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil, mode: .chatty,
                                  displays: [], tokens: TokenUsage()),
        events: [
            .sentence(id: UUID(), text: "make it bigger", start: 1, end: 2),
            .aiQuestion(id: q, sentenceID: UUID(), text: "Which button?", options: ["Save", "Cancel"], t: 3),
            .questionAnswered(id: q, answer: "Save", via: .click, t: 4),
            .questionAnswered(id: UUID(), answer: "", via: .skipped, t: 30),
        ])
    try SessionStore.save(doc, to: folder)
    #expect(try SessionStore.load(from: folder) == doc)
}

/// A session.json written by phase 2 (no Chatty events) must still open, e.g. for "Regenerate Last Report".
@Test func phase2SessionFileStillDecodes() throws {
    let json = """
    {
      "events" : [
        { "urlChanged" : { "t" : 0.5, "title" : "Home", "url" : "http://localhost:3000/" } },
        { "sentence" : { "end" : 3, "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF", "start" : 1, "text" : "this card is cramped" } },
        { "aiAnnotation" : {
            "annotations" : [ { "author" : "ai", "caption" : "Billing card", "createdAt" : 3, "displayID" : 1,
                                "id" : "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
                                "shape" : { "rect" : { "_0" : [[10, 20], [30, 40]] } } } ],
            "sentenceID" : "6F9619FF-8B86-D011-B42D-00C04FC964FF" } },
        { "momentMarked" : { "t" : 4 } }
      ],
      "metadata" : {
        "displays" : [ { "frame" : [[0, 0], [1512, 982]], "id" : 1, "scale" : 2 } ],
        "mode" : "live",
        "startedAt" : "2026-11-23T14:30:00Z",
        "tokens" : { "input" : 10, "output" : 2 }
      }
    }
    """
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let folder = try SessionFolder.create(root: dir, slug: "phase2", date: Date(timeIntervalSince1970: 1_700_000_000), timeZone: .gmt)
    try Data(json.utf8).write(to: folder.documentURL)
    let doc = try SessionStore.load(from: folder)
    #expect(doc.metadata.mode == .live)
    #expect(doc.events.count == 4)
    guard case let .aiAnnotation(sentenceID, annotations, say) = doc.events[2] else { Issue.record("no aiAnnotation"); return }
    #expect(sentenceID == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    #expect(annotations.first?.caption == "Billing card")
    #expect(say == nil)
    #expect(MomentSegmenter.segment(doc.events).count == 1)
}
