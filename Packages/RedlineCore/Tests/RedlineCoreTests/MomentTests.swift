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
