import CoreGraphics
import Foundation

public enum Palette {
    public static let user = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    public static let ai = CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
    public static let highlight = CGColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 0.35)
}

public enum AnnotationCompositor {
    /// Draws `annotations` (global points) onto `image`, a capture covering `display`.
    public static func compose(image: CGImage, display: DisplayGeometry, annotations: [Annotation]) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Switch to a top-left origin so pixel coordinates match the capture.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let size = CGSize(width: w, height: h)
        let toPixel: (CGPoint) -> CGPoint = { CoordinateMapper.imagePoint(fromGlobal: $0, imageSize: size, on: display) }
        let pixelsPerPoint = Double(w) / display.frame.width
        ctx.setLineWidth(max(3, 2 * pixelsPerPoint))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for a in annotations where a.displayID == display.id {
            let color = a.author == .user ? Palette.user : Palette.ai
            ctx.setStrokeColor(color)
            switch a.shape.mapped(toPixel, lengthScale: pixelsPerPoint) {
            case let .circle(c, r):
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            case let .rect(r):
                ctx.stroke(r)
            case let .highlight(r):
                ctx.setFillColor(Palette.highlight)
                ctx.fill(r)
            case let .arrow(from, to):
                drawArrow(ctx, from: from, to: to, headLength: 14 * pixelsPerPoint)
            case let .stroke(points):
                guard let first = points.first else { continue }
                ctx.beginPath()
                ctx.move(to: first)
                for p in points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    private static func drawArrow(_ ctx: CGContext, from: CGPoint, to: CGPoint, headLength: Double) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        ctx.beginPath()
        ctx.move(to: from)
        ctx.addLine(to: to)
        for side in [-1.0, 1.0] {
            let a = angle + .pi + side * .pi / 7
            ctx.move(to: to)
            ctx.addLine(to: CGPoint(x: to.x + headLength * cos(a), y: to.y + headLength * sin(a)))
        }
        ctx.strokePath()
    }
}
