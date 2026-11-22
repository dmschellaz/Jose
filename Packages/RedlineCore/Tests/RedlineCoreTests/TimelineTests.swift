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
