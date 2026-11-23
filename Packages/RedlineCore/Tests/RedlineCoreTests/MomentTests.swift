import Testing
import Foundation
import CoreGraphics
@testable import RedlineCore

private func s(_ text: String, _ start: Double, _ end: Double) -> TimelineEvent {
    .sentence(id: UUID(), text: text, start: start, end: end)
}
private func kf(_ t: Double, _ name: String) -> TimelineEvent {
    .keyframe(KeyframeRef(id: UUID(), file: name, t: t, displayID: 1), reason: .periodic)
}
private func mark(_ t: Double) -> Annotation {
    Annotation(shape: .stroke([.zero, CGPoint(x: 1, y: 1)]), caption: nil, author: .user, createdAt: t, displayID: 1)
}

@Test func splitsOnLongGap() {
    let m = MomentSegmenter.segment([s("a", 0, 2), s("b", 3, 4), s("c", 9, 10)])
    #expect(m.map(\.text) == ["a b", "c"])
    #expect(m.map(\.id) == [1, 2])
}

@Test func splitsOnURLChangeAndMark() {
    let m = MomentSegmenter.segment([
        .urlChanged(url: "http://x/a", title: nil, t: 0),
        s("a", 1, 2),
        .urlChanged(url: "http://x/b", title: nil, t: 2.5),
        s("b", 3, 4),
        .momentMarked(t: 4.2),
        s("c", 4.5, 5),
    ])
    #expect(m.map(\.text) == ["a", "b", "c"])
    #expect(m.map(\.url) == ["http://x/a", "http://x/b", "http://x/b"])
}

@Test func marksAndClicksGoToNearestMoment() {
    let m = MomentSegmenter.segment([s("a", 0, 2), .userMark(mark(3)), s("b", 10, 12), .click(point: .zero, displayID: 1, t: 9)])
    #expect(m[0].userMarks.count == 1)
    #expect(m[1].clickTimes == [9])
}

@Test func marksWithoutSpeechBecomeMoments() {
    let m = MomentSegmenter.segment([.userMark(mark(2)), .momentMarked(t: 8), kf(2.1, "a.png"), kf(8.2, "b.png")])
    #expect(m.count == 2)
    #expect(m[0].userMarks.count == 1)
    #expect(m.map { $0.keyframe?.file } == ["a.png", "b.png"])
}

@Test func keyframeNearestToMarkElseMidpoint() {
    let m = MomentSegmenter.segment([s("a", 0, 10), kf(1, "early.png"), kf(5, "mid.png"), .userMark(mark(8.9)), kf(9, "late.png")])
    #expect(m[0].keyframe?.file == "late.png")
    let n = MomentSegmenter.segment([s("a", 0, 10), kf(1, "early.png"), kf(5, "mid.png"), kf(9, "late.png")])
    #expect(n[0].keyframe?.file == "mid.png")
}

@Test func emptyTimelineHasNoMoments() {
    #expect(MomentSegmenter.segment([kf(1, "a.png")]).isEmpty)
}

private func aiMark(_ t: Double, _ caption: String? = "Save button") -> Annotation {
    Annotation(shape: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)), caption: caption, author: .ai, createdAt: t, displayID: 1)
}

@Test func aiMarksAttachToTheirSentencesMoment() {
    let first = UUID()
    // The AI answered the first sentence late (t = 9.5), nearer to moment 2 by time.
    let m = MomentSegmenter.segment([
        .sentence(id: first, text: "a", start: 0, end: 2),
        .sentence(id: UUID(), text: "b", start: 10, end: 12),
        .aiAnnotation(sentenceID: first, annotations: [aiMark(9.5)], say: nil),
    ])
    #expect(m[0].aiMarks.count == 1)
    #expect(m[1].aiMarks.isEmpty)
}

@Test func aiMarksWithUnknownSentenceFallBackToNearest() {
    let m = MomentSegmenter.segment([
        s("a", 0, 2), s("b", 10, 12),
        .aiAnnotation(sentenceID: UUID(), annotations: [aiMark(11), aiMark(11.5)], say: nil),
    ])
    #expect(m[0].aiMarks.isEmpty)
    #expect(m[1].aiMarks.count == 2)
}

@Test func keyframeAnchorPrefersUserMarksThenAIMarksThenClicks() {
    var m = Moment(id: 1, start: 0, end: 10, sentences: [])
    #expect(KeyframeSelector.anchorTime(for: m) == 5)
    m.clickTimes = [2]
    #expect(KeyframeSelector.anchorTime(for: m) == 2.3)
    m.aiMarks = [aiMark(7), aiMark(9)]
    #expect(KeyframeSelector.anchorTime(for: m) == 9)
    m.userMarks = [mark(3), mark(4)]
    // A later AI mark doesn't pull the keyframe away from the reviewer's own mark.
    #expect(KeyframeSelector.anchorTime(for: m) == 4)

    let seg = MomentSegmenter.segment([
        s("a", 0, 10), .userMark(mark(3)), kf(3.1, "user.png"), kf(9, "ai.png"),
        .aiAnnotation(sentenceID: UUID(), annotations: [aiMark(9)], say: nil),
    ])
    #expect(seg[0].keyframe?.file == "user.png")
}
