import AppKit
import RedlineCore
import SwiftUI

struct ShownMark: Identifiable {
    let annotation: Annotation
    let shownAt: Date
    let lifetime: Double
    /// The hand-drawn strokes in global points, sketched once with the annotation's seed (the report PNG uses
    /// the same seed, so it matches what was on screen).
    let sketch: [[CGPoint]]
    /// Caption tilt in radians.
    let tilt: Double
    var id: UUID { annotation.id }

    init(annotation: Annotation, shownAt: Date, lifetime: Double) {
        self.annotation = annotation
        self.shownAt = shownAt
        self.lifetime = lifetime
        let seed = Sketch.seed(for: annotation.id)
        sketch = annotation.author == .ai ? Sketch.strokes(for: annotation.shape, seed: seed) : []
        tilt = Sketch.captionTilt(seed: seed)
    }
}

/// How an AI mark comes on: the shape draws on, then its caption is written out, and the whole mark
/// fades at the end of its lifetime.
enum MarkTiming {
    /// Seconds for the pen to draw the shape (ease-out).
    static let drawOn = 0.7
    /// Pause between the shape finishing and the caption starting.
    static let captionDelay = 0.05
    /// Seconds for the caption's left-to-right reveal.
    static let captionReveal = 0.4
    /// Seconds of fade at the end of the lifetime.
    static let fadeOut = 0.6

    /// Cubic ease-out over 0...1.
    static func easeOut(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return 1 - (1 - c) * (1 - c) * (1 - c)
    }
}

@MainActor @Observable
final class OverlayModel {
    let display: DisplayGeometry
    var marks: [ShownMark] = []
    var liveStroke: [CGPoint] = []   // local points
    var penActive = false
    init(display: DisplayGeometry) { self.display = display }
}

struct OverlayView: View {
    @Bindable var model: OverlayModel
    let onStroke: ([CGPoint]) -> Void

    var body: some View {
        // Runs every frame while any mark is on screen (drawing on, holding or fading) or a stroke is live.
        // OverlayController removes each mark just after its lifetime, which pauses it again.
        TimelineView(.animation(paused: model.marks.isEmpty && model.liveStroke.isEmpty)) { timeline in
            Canvas { gc, size in
                for mark in model.marks {
                    let age = timeline.date.timeIntervalSince(mark.shownAt)
                    let alpha = max(0, min(1, (mark.lifetime - age) / MarkTiming.fadeOut))
                    guard alpha > 0 else { continue }
                    let toLocal: (CGPoint) -> CGPoint = { CoordinateMapper.local(fromGlobal: $0, on: model.display) }
                    let local = mark.annotation.shape.mapped(toLocal, lengthScale: 1)
                    guard mark.annotation.author == .ai else {
                        draw(local, in: &gc, color: Color(cgColor: Palette.user), alpha: alpha)
                        continue
                    }
                    let progress = MarkTiming.easeOut(age / MarkTiming.drawOn)
                    drawSketch(mark.sketch.map { $0.map(toLocal) }, of: local, progress: progress, in: &gc, alpha: alpha)
                    let reveal = (age - MarkTiming.drawOn - MarkTiming.captionDelay) / MarkTiming.captionReveal
                    if reveal > 0, let caption = mark.annotation.caption, !caption.isEmpty {
                        drawCaption(caption, below: Self.bounds(of: local), tilt: mark.tilt, reveal: min(1, reveal),
                                    in: &gc, canvas: size, alpha: alpha)
                    }
                }
                if model.liveStroke.count > 1 {
                    draw(.stroke(model.liveStroke), in: &gc, color: Color(cgColor: Palette.user), alpha: 1)
                }
            }
        }
        // A faint tint while drawing: it shows pen mode and makes the window catch clicks (fully clear pixels pass through).
        .background(model.penActive ? Color.black.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    guard model.penActive else { return }
                    model.liveStroke.append(value.location)
                    NSCursor.crosshair.set()   // keep the pen cursor while drawing
                }
                .onEnded { _ in
                    if model.liveStroke.count > 1 { onStroke(model.liveStroke) }
                    model.liveStroke = []
                }
        )
    }

    /// The AI's pen: the first `progress` of the sketch by length, with a dot at the tip while it draws.
    /// A highlight is a wide translucent marker stroked as one path, so overlapping passes stay one even tint.
    private func drawSketch(_ strokes: [[CGPoint]], of shape: AnnotationShape, progress: Double,
                            in gc: inout GraphicsContext, alpha: Double) {
        let visible = Sketch.trimmed(strokes, fraction: progress)
        var path = Path()
        for stroke in visible where stroke.count > 1 { path.addLines(stroke) }
        let ink = Color(cgColor: Palette.ai)
        if case let .highlight(r) = shape {
            gc.stroke(path, with: .color(Color(cgColor: Palette.highlight).opacity(alpha)),
                      style: StrokeStyle(lineWidth: Sketch.markerWidth(for: r), lineCap: .round, lineJoin: .round))
        } else {
            gc.stroke(path, with: .color(ink.opacity(alpha)),
                      style: StrokeStyle(lineWidth: AnnotationCompositor.aiPenWidth, lineCap: .round, lineJoin: .round))
            if progress < 1, let tip = visible.last?.last {
                let r = 2.6
                gc.fill(Path(ellipseIn: CGRect(x: tip.x - r, y: tip.y - r, width: 2 * r, height: 2 * r)),
                        with: .color(ink.opacity(alpha)))
            }
        }
    }

    /// A handwritten caption in AI blue with a soft white halo, tilted by `tilt` radians and written out
    /// left to right (`reveal` 0...1). It sits below-right of the mark's bounding box and stays on screen.
    private func drawCaption(_ caption: String, below box: CGRect, tilt: Double, reveal: Double,
                             in gc: inout GraphicsContext, canvas: CGSize, alpha: Double) {
        let font = Font.custom(Handwriting.fontName, size: Handwriting.size)   // falls back to the system font
        let text = gc.resolve(Text(caption).font(font).foregroundStyle(Color(cgColor: Palette.ai)))
        let maxTextWidth = min(360, canvas.width - 40)
        let textSize = text.measure(in: CGSize(width: maxTextWidth, height: 200))
        let halo: CGFloat = 4, gap: CGFloat = 6, margin: CGFloat = 8
        // The label's footprint is the tilted text's bounding box plus room for the halo.
        let cosT = abs(cos(tilt)), sinT = abs(sin(tilt))
        let label = CGSize(width: textSize.width * cosT + textSize.height * sinT + 2 * halo,
                           height: textSize.width * sinT + textSize.height * cosT + 2 * halo)

        // Below-right of the shape; flip above if there's no room below, then clamp to the screen.
        var origin = CGPoint(x: box.maxX - min(box.width, 24), y: box.maxY + gap)
        if origin.y + label.height > canvas.height - margin { origin.y = box.minY - gap - label.height }
        origin.x = min(max(margin, origin.x), canvas.width - margin - label.width)
        origin.y = min(max(margin, origin.y), canvas.height - margin - label.height)
        let frame = CGRect(origin: origin, size: label)

        gc.drawLayer { layer in
            layer.opacity = alpha
            layer.translateBy(x: frame.midX, y: frame.midY)
            layer.rotate(by: .radians(tilt))
            let textRect = CGRect(x: -textSize.width / 2, y: -textSize.height / 2, width: textSize.width, height: textSize.height)
            // The pen writes left to right: a mask sweeps across the text, halo included.
            layer.clip(to: Path(CGRect(x: textRect.minX - halo, y: textRect.minY - halo,
                                       width: (textRect.width + 2 * halo) * reveal, height: textRect.height + 2 * halo)))
            layer.addFilter(.shadow(color: .white, radius: 1))
            layer.addFilter(.shadow(color: .white.opacity(0.85), radius: 2.5))
            layer.draw(text, in: textRect)
        }
    }

    /// Bounding box of a shape in local points.
    private static func bounds(of shape: AnnotationShape) -> CGRect {
        switch shape {
        case let .circle(center, r): CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        case let .rect(r), let .highlight(r): r
        case let .arrow(from, to): CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
        case let .stroke(points):
            points.dropFirst().reduce(CGRect(origin: points.first ?? .zero, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
    }

    private func draw(_ shape: AnnotationShape, in gc: inout GraphicsContext, color: Color, alpha: Double) {
        let style = StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
        let c = color.opacity(alpha)
        switch shape {
        case let .circle(center, r):
            gc.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)), with: .color(c), style: style)
        case let .rect(r):
            gc.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(c), style: style)
        case let .highlight(r):
            gc.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color(cgColor: Palette.highlight).opacity(alpha)))
        case let .arrow(from, to):
            var p = Path()
            p.move(to: from)
            p.addLine(to: to)
            let angle = atan2(to.y - from.y, to.x - from.x)
            for side in [-1.0, 1.0] {
                let a = angle + .pi + side * .pi / 7
                p.move(to: to)
                p.addLine(to: CGPoint(x: to.x + 14 * cos(a), y: to.y + 14 * sin(a)))
            }
            gc.stroke(p, with: .color(c), style: style)
        case let .stroke(points):
            var p = Path()
            p.addLines(points)
            gc.stroke(p, with: .color(c), style: style)
        }
    }
}
