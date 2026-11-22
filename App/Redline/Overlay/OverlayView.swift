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
            Canvas { gc, _ in
                for mark in model.marks {
                    let remaining = mark.lifetime - timeline.date.timeIntervalSince(mark.shownAt)
                    let alpha = max(0, min(1, remaining / 0.6))
                    guard alpha > 0 else { continue }
                    let local = mark.annotation.shape.mapped({ CoordinateMapper.local(fromGlobal: $0, on: model.display) }, lengthScale: 1)
                    draw(local, in: &gc, color: mark.annotation.author == .user ? Color(cgColor: Palette.user) : Color(cgColor: Palette.ai), alpha: alpha)
                }
                if model.liveStroke.count > 1 {
                    draw(.stroke(model.liveStroke), in: &gc, color: Color(cgColor: Palette.user), alpha: 1)
                }
            }
        }
        // A faint tint while drawing: it shows pen mode and makes the window catch clicks (fully clear pixels pass through).
        .background(model.penActive ? Color.black.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in if model.penActive { model.liveStroke.append(value.location) } }
                .onEnded { _ in
                    if model.liveStroke.count > 1 { onStroke(model.liveStroke) }
                    model.liveStroke = []
                }
        )
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
