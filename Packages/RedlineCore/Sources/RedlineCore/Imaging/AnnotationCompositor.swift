import CoreGraphics
import CoreText
import Foundation

public enum Palette {
    public static let user = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    public static let ai = CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
    public static let highlight = CGColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 0.35)
    public static let labelBackground = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.9)
    public static let labelText = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
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

        let visible = annotations.filter { $0.displayID == display.id }
        for a in visible {
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
        // Captions go on top of every shape so no stroke crosses a label.
        for a in visible {
            guard let caption = a.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else { continue }
            drawLabel(ctx, caption: caption, author: a.author,
                      shapeBounds: labelAnchor(a.shape.mapped(toPixel, lengthScale: pixelsPerPoint)),
                      imageSize: size, pixelsPerPoint: pixelsPerPoint)
        }
        return ctx.makeImage()
    }

    // MARK: Captions

    /// Where a label of `labelSize` goes for a shape occupying `shapeBounds`, in top-left-origin pixels:
    /// below the shape, left-aligned with it; above it if there's no room below; always inside the image.
    public static func labelRect(for labelSize: CGSize, shapeBounds: CGRect, imageSize: CGSize, gap: Double = 6) -> CGRect {
        let w = min(labelSize.width, imageSize.width)
        let h = min(labelSize.height, imageSize.height)
        var y = shapeBounds.maxY + gap
        if y + h > imageSize.height { y = shapeBounds.minY - gap - h }
        y = min(max(0, y), imageSize.height - h)
        let x = min(max(0, shapeBounds.minX), imageSize.width - w)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The region a caption should sit next to. Arrows are labelled at their tail, away from the target.
    static func labelAnchor(_ shape: AnnotationShape) -> CGRect {
        switch shape {
        case let .circle(c, r): return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case let .rect(r), let .highlight(r): return r.standardized
        case let .arrow(from, _): return CGRect(origin: from, size: .zero)
        case let .stroke(points):
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
    }

    /// A dark rounded label with white text and a coloured left accent (blue for the AI), about 12 pt.
    private static func drawLabel(_ ctx: CGContext, caption: String, author: AnnotationAuthor,
                                  shapeBounds: CGRect, imageSize: CGSize, pixelsPerPoint: Double) {
        let ppp = CGFloat(pixelsPerPoint)
        let font = CTFontCreateUIFontForLanguage(.system, 12 * ppp, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 12 * ppp, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.labelText,
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: caption, attributes: attributes))

        let padX = 6 * ppp, padY = 3 * ppp, accent = 3 * ppp
        let chrome = 2 * padX + accent
        let maxTextWidth = max(0, imageSize.width - chrome)
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxTextWidth {
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            line = CTLineCreateTruncatedLine(line, Double(maxTextWidth), .end, ellipsis) ?? line
        }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let size = CGSize(width: textWidth + chrome, height: ascent + descent + 2 * padY)
        let box = labelRect(for: size, shapeBounds: shapeBounds, imageSize: imageSize, gap: 6 * pixelsPerPoint)

        let path = CGPath(roundedRect: box, cornerWidth: 4 * ppp, cornerHeight: 4 * ppp, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(Palette.labelBackground)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(author == .ai ? Palette.ai : Palette.user)
        ctx.fill(CGRect(x: box.minX, y: box.minY, width: accent, height: box.height))
        ctx.restoreGState()

        // The context is flipped (top-left origin); flip back locally so the glyphs stand upright.
        ctx.saveGState()
        ctx.translateBy(x: box.minX + accent + padX, y: box.minY + padY + ascent)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
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
