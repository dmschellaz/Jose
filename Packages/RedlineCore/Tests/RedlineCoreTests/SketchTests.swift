import Testing
import CoreGraphics
import Foundation
@testable import RedlineCore

private let shapes: [AnnotationShape] = [
    .circle(center: CGPoint(x: 200, y: 150), radius: 60),
    .rect(CGRect(x: 40, y: 50, width: 180, height: 90)),
    .arrow(from: CGPoint(x: 10, y: 300), to: CGPoint(x: 220, y: 180)),
    .highlight(CGRect(x: 30, y: 400, width: 260, height: 50)),
]

private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

@Test func sketchIsDeterministicPerSeed() {
    for shape in shapes {
        #expect(Sketch.strokes(for: shape, seed: 42) == Sketch.strokes(for: shape, seed: 42))
        #expect(Sketch.strokes(for: shape, seed: 42) != Sketch.strokes(for: shape, seed: 43))
    }
}

@Test func seedComesFromTheAnnotationID() {
    let id = UUID()
    #expect(Sketch.seed(for: id) == Sketch.seed(for: id))
    #expect(Sketch.seed(for: id) != Sketch.seed(for: UUID()))
    let tilt = Sketch.captionTilt(seed: Sketch.seed(for: id))
    #expect(abs(tilt) <= 3 * .pi / 180)
}

@Test func circleStaysInTheRadiusBandAndOvershoots() {
    let center = CGPoint(x: 200, y: 150)
    for seed in UInt64(0)..<50 {
        for radius in [8.0, 60, 400] {
            let strokes = Sketch.strokes(for: .circle(center: center, radius: radius), seed: seed)
            #expect(strokes.count == 1)
            let points = strokes[0]
            #expect(points.allSatisfy { abs(dist($0, center) - radius) <= 0.15 * radius })
            // More than one turn: the swept angle passes 2π, so the end passes the start.
            var swept = 0.0
            for (a, b) in zip(points, points.dropFirst()) {
                var d = atan2(b.y - center.y, b.x - center.x) - atan2(a.y - center.y, a.x - center.x)
                if d > .pi { d -= 2 * .pi } else if d < -.pi { d += 2 * .pi }
                swept += d
            }
            #expect(abs(swept) >= 1.09 * 2 * .pi && abs(swept) <= 1.21 * 2 * .pi)
        }
    }
}

@Test func rectSidesHugTheRect() {
    let r = CGRect(x: 40, y: 50, width: 180, height: 90)
    for seed in UInt64(0)..<20 {
        let strokes = Sketch.strokes(for: .rect(r), seed: seed)
        #expect((1...2).contains(strokes.count))
        let points = strokes.flatMap { $0 }
        #expect(points.allSatisfy { r.insetBy(dx: -8, dy: -8).contains($0) && !r.insetBy(dx: 8, dy: 8).contains($0) })
    }
}

@Test func arrowEndsAtTheTip() {
    let from = CGPoint(x: 10, y: 300), to = CGPoint(x: 220, y: 180)
    for seed in UInt64(0)..<20 {
        let strokes = Sketch.strokes(for: .arrow(from: from, to: to), seed: seed)
        #expect(strokes.count == 3)
        #expect(dist(strokes[0].first!, from) < 1)
        #expect(dist(strokes[0].last!, to) < 1)
        // Both head strokes start at the tip and stay short.
        for head in strokes.dropFirst() {
            #expect(dist(head.first!, to) < 1)
            #expect(dist(head.last!, to) <= 20)
        }
    }
}

@Test func highlightCoversTheRect() {
    let r = CGRect(x: 30, y: 400, width: 260, height: 50)
    let strokes = Sketch.strokes(for: .highlight(r), seed: 7)
    let width = Sketch.markerWidth(for: r)
    let points = strokes.flatMap { $0 }
    // Passes are centred inside the rect and the marker is wide enough that they overlap into a band.
    #expect(points.allSatisfy { r.insetBy(dx: -3, dy: 0).contains($0) })
    #expect(width > r.height / 3)   // three 16.7-pt bands, overlapping
    #expect(points.map(\.x).min()! < r.minX + width && points.map(\.x).max()! > r.maxX - width)
}

@Test func userStrokeIsUnchanged() {
    let points = [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 5), CGPoint(x: 8, y: 4)]
    #expect(Sketch.strokes(for: .stroke(points), seed: 99) == [points])
}

@Test func trimmedDrawsOnByLength() {
    for shape in shapes {
        let strokes = Sketch.strokes(for: shape, seed: 3)
        let total = Sketch.totalLength(strokes)
        #expect(total > 0)
        #expect(Sketch.trimmed(strokes, fraction: 0).isEmpty)
        #expect(Sketch.trimmed(strokes, fraction: -1).isEmpty)
        #expect(Sketch.trimmed(strokes, fraction: 1) == strokes)
        let half = Sketch.trimmed(strokes, fraction: 0.5)
        #expect(abs(Sketch.totalLength(half) - total / 2) < total * 0.01)
        // Monotonic: a later fraction never draws less.
        #expect(Sketch.totalLength(Sketch.trimmed(strokes, fraction: 0.3)) < Sketch.totalLength(Sketch.trimmed(strokes, fraction: 0.6)))
    }
}

@Test func totalLengthOfASquare() {
    let square = [[CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)], [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 10)]]
    #expect(Sketch.totalLength(square) == 30)
    let quarter = Sketch.trimmed(square, fraction: 0.25)
    #expect(quarter.count == 1 && quarter[0].last == CGPoint(x: 7.5, y: 0))
}
