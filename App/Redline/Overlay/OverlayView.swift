import AppKit
import RedlineCore
import SwiftUI

struct ShownMark: Identifiable {
    let annotation: Annotation
    let shownAt: Date
    let lifetime: Double
    var id: UUID { annotation.id }
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
        TimelineView(.animation(paused: model.marks.isEmpty && model.liveStroke.isEmpty)) { timeline in
            Canvas { gc, size in
                for mark in model.marks {
                    let remaining = mark.lifetime - timeline.date.timeIntervalSince(mark.shownAt)
                    let alpha = max(0, min(1, remaining / 0.6))
                    guard alpha > 0 else { continue }
                    let local = mark.annotation.shape.mapped({ CoordinateMapper.local(fromGlobal: $0, on: model.display) }, lengthScale: 1)
                    draw(local, in: &gc, color: mark.annotation.author == .user ? Color(cgColor: Palette.user) : Color(cgColor: Palette.ai), alpha: alpha)
                    if mark.annotation.author == .ai, let caption = mark.annotation.caption, !caption.isEmpty {
                        drawCaption(caption, below: Self.bounds(of: local), in: &gc, canvas: size, alpha: alpha)
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

    /// A small dark rounded label with white text and an AI-blue accent bar, placed below-right of
    /// the mark's bounding box and kept on screen.
    private func drawCaption(_ caption: String, below box: CGRect, in gc: inout GraphicsContext, canvas: CGSize, alpha: Double) {
        let text = gc.resolve(Text(caption).font(.system(size: 12, weight: .medium)).foregroundStyle(.white))
        let maxTextWidth = min(360, canvas.width - 40)
        let textSize = text.measure(in: CGSize(width: maxTextWidth, height: 60))
        let accent: CGFloat = 3, padH: CGFloat = 8, padV: CGFloat = 5, gap: CGFloat = 8, margin: CGFloat = 8
        let label = CGSize(width: accent + padH * 2 + textSize.width, height: textSize.height + padV * 2)

        // Below-right of the shape; flip above if there's no room below, then clamp to the screen.
        var origin = CGPoint(x: box.maxX - min(box.width, 24), y: box.maxY + gap)
        if origin.y + label.height > canvas.height - margin { origin.y = box.minY - gap - label.height }
        origin.x = min(max(margin, origin.x), canvas.width - margin - label.width)
        origin.y = min(max(margin, origin.y), canvas.height - margin - label.height)
        let frame = CGRect(origin: origin, size: label)

        let bg = Path(roundedRect: frame, cornerRadius: 6)
        gc.fill(bg, with: .color(Color.black.opacity(0.82 * alpha)))
        gc.drawLayer { layer in
            layer.clip(to: bg)
            layer.fill(Path(CGRect(x: frame.minX, y: frame.minY, width: accent, height: frame.height)),
                       with: .color(Color(cgColor: Palette.ai).opacity(alpha)))
        }
        gc.stroke(bg, with: .color(Color(cgColor: Palette.ai).opacity(0.6 * alpha)), lineWidth: 1)
        gc.opacity = alpha
        gc.draw(text, in: CGRect(x: frame.minX + accent + padH, y: frame.minY + padV, width: textSize.width, height: textSize.height))
        gc.opacity = 1
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
