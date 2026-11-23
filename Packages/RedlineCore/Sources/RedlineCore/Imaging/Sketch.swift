import CoreGraphics
import Foundation

/// A small, fast, seedable RNG (SplitMix64). The same seed always yields the same sequence.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform value in `range`.
    mutating func value(_ range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    /// +1 or -1.
    mutating func sign() -> Double { next() & 1 == 0 ? 1 : -1 }
}

/// Turns geometric annotation shapes into hand-drawn-looking polylines, deterministically per seed.
///
/// Strokes come back in the shape's own coordinate space. Wobble is proportional to the shape's size but
/// capped in absolute units; the caps are tuned for points, so sketch in points and map the result to
/// pixels (as the compositor does) when the screen and the PNG should match exactly.
public enum Sketch {
    /// A stable seed derived from an annotation's id, so a mark looks the same on screen and in the report.
    public static func seed(for id: UUID) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325   // FNV-1a
        withUnsafeBytes(of: id.uuid) { bytes in
            for b in bytes { hash = (hash ^ UInt64(b)) &* 0x100_0000_01B3 }
        }
        return hash
    }

    /// Caption tilt in radians, within ±3°, derived from the seed (independent of the stroke stream).
    public static func captionTilt(seed: UInt64) -> Double {
        var rng = SplitMix64(seed: seed ^ 0x5EED_CA97_10A0_0001)
        return rng.value(-3...3) * .pi / 180
    }

    /// Width of the marker used for a highlight's strokes, in the shape's units.
    public static func markerWidth(for rect: CGRect) -> Double {
        let h = max(1, rect.standardized.height)
        return h / Double(highlightPasses(height: h)) * 1.2
    }

    /// One or more polylines that draw `shape` as if by hand. A user `.stroke` is returned unchanged.
    public static func strokes(for shape: AnnotationShape, seed: UInt64) -> [[CGPoint]] {
        var rng = SplitMix64(seed: seed)
        switch shape {
        case let .circle(center, radius): return circle(center: center, radius: radius, rng: &rng)
        case let .rect(r): return rect(r.standardized, rng: &rng)
        case let .arrow(from, to): return arrow(from: from, to: to, rng: &rng)
        case let .highlight(r): return highlight(r.standardized, rng: &rng)
        case let .stroke(points): return [points]
        }
    }

    // MARK: Draw-on helpers

    /// Sum of the lengths of every stroke.
    public static func totalLength(_ strokes: [[CGPoint]]) -> Double {
        strokes.reduce(0) { $0 + length($1) }
    }

    /// The first `fraction` (0...1) of the strokes by length, in drawing order. The stroke being drawn ends
    /// at an interpolated point, so its last point is the pen tip.
    public static func trimmed(_ strokes: [[CGPoint]], fraction: Double) -> [[CGPoint]] {
        guard fraction > 0 else { return [] }
        guard fraction < 1 else { return strokes }
        var budget = totalLength(strokes) * fraction
        var out: [[CGPoint]] = []
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            var partial = [first]
            for (a, b) in zip(stroke, stroke.dropFirst()) {
                let d = distance(a, b)
                if d >= budget {
                    let t = d > 0 ? budget / d : 0
                    partial.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                    out.append(partial)
                    return out
                }
                budget -= d
                partial.append(b)
            }
            out.append(partial)
        }
        return out
    }

    // MARK: Shapes

    /// A loose ellipse, about 1.1-1.2 turns, slightly tilted and squashed, whose radius wobbles and drifts
    /// so the end passes beside the start as a real pen circle does. Every point stays within ~12% of `radius`.
    private static func circle(center: CGPoint, radius: Double, rng: inout SplitMix64) -> [[CGPoint]] {
        let r = max(radius, 0.5)
        let turns = rng.value(1.1...1.2)
        let start = rng.value(0...(2 * .pi))
        let tilt = rng.value(-0.35...0.35)
        let squash = rng.value(0.02...0.05)             // ellipse: rx = r(1+s), ry = r(1-s)
        let wobbleAmp = min(0.03 * r, 3.0)              // proportional, capped in absolute units
        let w1 = rng.value(0.4...1) * wobbleAmp, p1 = rng.value(0...(2 * .pi))
        let w2 = rng.value(0.2...0.6) * wobbleAmp, p2 = rng.value(0...(2 * .pi))
        let drift = rng.sign() * rng.value(0.02...0.04)  // radius change over the whole stroke
        let direction = rng.next() % 4 == 0 ? -1.0 : 1.0  // mostly one way, like most people

        let sweep = turns * 2 * .pi
        let n = Int(min(240, max(36, sweep * r / 4)))
        var points: [CGPoint] = []
        points.reserveCapacity(n + 1)
        for i in 0...n {
            let t = Double(i) / Double(n)
            let theta = start + direction * sweep * t
            let rr = 1 + drift * (t - 0.5) * 2
            let wobble = w1 * sin(2 * theta + p1) + w2 * sin(3 * theta + p2)
            let local = CGPoint(x: (r * (1 + squash) * rr + wobble) * cos(theta),
                                y: (r * (1 - squash) * rr + wobble) * sin(theta))
            points.append(CGPoint(x: center.x + local.x * cos(tilt) - local.y * sin(tilt),
                                  y: center.y + local.x * sin(tilt) + local.y * cos(tilt)))
        }
        return [points]
    }

    /// Four slightly bowed sides with little overshoots past the corners, in two strokes:
    /// top then right, and left then bottom.
    private static func rect(_ r: CGRect, rng: inout SplitMix64) -> [[CGPoint]] {
        let size = max(min(r.width, r.height), 1)
        let jitter = min(0.03 * size, 2.0)
        func corner(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x + rng.value(-jitter...jitter), y: y + rng.value(-jitter...jitter))
        }
        let tl = corner(r.minX, r.minY), tr = corner(r.maxX, r.minY)
        let br = corner(r.maxX, r.maxY), bl = corner(r.minX, r.maxY)

        /// A bowed line from `a` to `b`, extended past both ends by small overshoots.
        func side(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
            let len = max(distance(a, b), 0.001)
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            let overshootCap = min(0.06 * len, 5.0)
            let lead = rng.value(0...(overshootCap * 0.5)), tail = rng.value((overshootCap * 0.4)...overshootCap)
            let bow = rng.sign() * rng.value(0.4...1) * min(0.025 * len, 4.0)
            let n = Int(min(60, max(8, len / 6)))
            return (0...n).map { i in
                let t = Double(i) / Double(n)
                let along = -lead + (len + lead + tail) * t
                let off = bow * sin(.pi * min(max(along / len, 0), 1))
                return CGPoint(x: a.x + ux * along - uy * off, y: a.y + uy * along + ux * off)
            }
        }
        let first = side(tl, tr) + side(tr, br)
        let second = side(tl, bl) + side(bl, br)
        return [first, second]
    }

    /// A gently curved shaft ending exactly at the tip, then two short head strokes from the tip.
    private static func arrow(from: CGPoint, to: CGPoint, rng: inout SplitMix64) -> [[CGPoint]] {
        let len = distance(from, to)
        guard len > 0.5 else { return [[from, to]] }
        let ux = (to.x - from.x) / len, uy = (to.y - from.y) / len
        let bend = rng.sign() * rng.value(0.04...0.08) * len
        let bendCapped = max(-12, min(12, bend))
        let control = CGPoint(x: (from.x + to.x) / 2 - uy * bendCapped, y: (from.y + to.y) / 2 + ux * bendCapped)
        let n = Int(min(80, max(12, len / 5)))
        let shaft = (0...n).map { i -> CGPoint in
            let t = Double(i) / Double(n), m = 1 - t
            return CGPoint(x: m * m * from.x + 2 * m * t * control.x + t * t * to.x,
                           y: m * m * from.y + 2 * m * t * control.y + t * t * to.y)
        }
        // The head follows the shaft's direction where it arrives.
        let angle = atan2(to.y - control.y, to.x - control.x)
        let headLength = min(max(0.22 * len, 6), 16)
        let heads: [[CGPoint]] = [-1.0, 1.0].map { side in
            let a = angle + .pi + side * (.pi / 7 + rng.value(-0.12...0.12))
            let l = headLength * rng.value(0.85...1.1)
            let end = CGPoint(x: to.x + l * cos(a), y: to.y + l * sin(a))
            let curl = rng.value(-0.08...0.08) * l
            let mid = CGPoint(x: (to.x + end.x) / 2 - sin(a) * curl, y: (to.y + end.y) / 2 + cos(a) * curl)
            return [to, mid, end]
        }
        return [shaft] + heads
    }

    private static func highlightPasses(height: Double) -> Int { max(1, Int((height / 22).rounded(.up))) }

    /// A marker zig-zag back and forth across the rect, one pass per band; stroke it with `markerWidth(for:)`
    /// as a single path so the overlapping translucent passes stay one even tint.
    private static func highlight(_ r: CGRect, rng: inout SplitMix64) -> [[CGPoint]] {
        let h = max(1, r.height)
        let passes = highlightPasses(height: h)
        let band = h / Double(passes)
        let width = markerWidth(for: r)
        let inset = width * 0.35                        // round caps reach roughly to the edges
        let wobble = min(0.08 * band, 1.5)
        var points: [CGPoint] = []
        for i in 0..<passes {
            let y = r.minY + (Double(i) + 0.5) * band
            let leftToRight = i % 2 == 0
            let slant = rng.value(-0.12...0.12) * band
            let x0 = r.minX + inset - rng.value(0...2), x1 = r.maxX - inset + rng.value(0...2)
            let segments = Int(min(40, max(4, r.width / 12)))
            for s in 0...segments {
                let t = Double(s) / Double(segments)
                let u = leftToRight ? t : 1 - t
                points.append(CGPoint(x: x0 + (x1 - x0) * u,
                                      y: y + slant * (u - 0.5) * 2 + rng.value(-wobble...wobble)))
            }
        }
        return [points]
    }

    // MARK: Geometry

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(b.x - a.x, b.y - a.y) }

    private static func length(_ stroke: [CGPoint]) -> Double {
        zip(stroke, stroke.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }
}
