import CoreGraphics
import CoreText
import Foundation

public enum Palette {
    public static let user = CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    public static let ai = CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
    public static let highlight = CGColor(srgbRed: 1, green: 0.85, blue: 0, alpha: 0.35)
    public static let labelBackground = CGColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 0.9)
    public static let labelText = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// The halo behind handwritten captions, so they read on any background.
    public static let halo = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
}

/// The handwriting used for captions, on screen and in report PNGs.
public enum Handwriting {
    /// Noteworthy Bold ships with macOS and stays legible at small sizes, unlike the script faces.
    public static let fontName = "Noteworthy-Bold"
    /// Caption size in points.
    public static let size: Double = 17

    /// The caption font at `size` (in whatever units the caller draws in), falling back to the system font.
    public static func font(size: Double) -> CTFont {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        if CTFontCopyPostScriptName(font) as String == fontName { return font }
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? font
    }
}

public enum AnnotationCompositor {
    /// The AI's pen width, in points; it matches the overlay.
    public static let aiPenWidth: Double = 3

    /// Draws `annotations` (global points) onto `image`, a capture covering `display`.
    /// AI marks are sketched with `Sketch` using the annotation's seed, so they match what was on screen.
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
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let visible = annotations.filter { $0.displayID == display.id }
        for a in visible {
            if a.author == .ai {
                drawSketch(ctx, a, toPixel: toPixel, pixelsPerPoint: pixelsPerPoint)
            } else {
                drawPlain(ctx, a.shape.mapped(toPixel, lengthScale: pixelsPerPoint), pixelsPerPoint: pixelsPerPoint)
            }
        }
        // Captions go on top of every shape so no stroke crosses a label.
        for a in visible {
            guard let caption = a.caption?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty else { continue }
            drawLabel(ctx, caption: caption, color: a.author == .user ? Palette.user : Palette.ai,
                      tilt: Sketch.captionTilt(seed: Sketch.seed(for: a.id)),
                      shapeBounds: labelAnchor(a.shape.mapped(toPixel, lengthScale: pixelsPerPoint)),
                      imageSize: size, pixelsPerPoint: pixelsPerPoint)
        }
        return ctx.makeImage()
    }

    /// Hand-drawn strokes, sketched in global points (where the wobble caps are tuned) and then mapped.
    private static func drawSketch(_ ctx: CGContext, _ a: Annotation, toPixel: (CGPoint) -> CGPoint, pixelsPerPoint: Double) {
        let strokes = Sketch.strokes(for: a.shape, seed: Sketch.seed(for: a.id)).map { $0.map(toPixel) }
        ctx.beginPath()
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            ctx.move(to: first)
            for p in stroke.dropFirst() { ctx.addLine(to: p) }
        }
        if case let .highlight(r) = a.shape {
            // One path, so overlapping marker passes stay a single even tint.
            ctx.setLineWidth(Sketch.markerWidth(for: r) * pixelsPerPoint)
            ctx.setStrokeColor(Palette.highlight)
        } else {
            ctx.setLineWidth(aiPenWidth * pixelsPerPoint)
            ctx.setStrokeColor(Palette.ai)
        }
        ctx.strokePath()
    }

    /// The user's marks, crisp, as they appeared on screen.
    private static func drawPlain(_ ctx: CGContext, _ shape: AnnotationShape, pixelsPerPoint: Double) {
        ctx.setLineWidth(max(3, 2 * pixelsPerPoint))
        ctx.setStrokeColor(Palette.user)
        switch shape {
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
            guard let first = points.first else { return }
            ctx.beginPath()
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        }
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

    /// A handwritten caption in the mark's colour with a white halo, tilted by `tilt` radians, placed with
    /// `labelRect` (its rotated bounds, halo included, stay inside the image).
    private static func drawLabel(_ ctx: CGContext, caption: String, color: CGColor, tilt: Double,
                                  shapeBounds: CGRect, imageSize: CGSize, pixelsPerPoint: Double) {
        let ppp = CGFloat(pixelsPerPoint)
        let font = Handwriting.font(size: Handwriting.size * ppp)
        let halo = 2.5 * ppp
        let ink: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        // The halo is the same glyphs stroked wide in white (a positive stroke width, in % of the font size,
        // means stroke only). It shares the font, so it truncates at the same place as the ink.
        let outline: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): Palette.halo,
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): 2 * halo / CTFontGetSize(font) * 100,
        ]

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let full = CTLineCreateWithAttributedString(NSAttributedString(string: caption, attributes: ink))
        let fullWidth = CGFloat(CTLineGetTypographicBounds(full, &ascent, &descent, &leading))
        let textHeight = ascent + descent
        let cosT = abs(cos(tilt)), sinT = abs(sin(tilt))

        // Fit the rotated text (plus halo) inside the image width.
        let maxTextWidth = max(0, (imageSize.width - 2 * halo - textHeight * sinT) / max(cosT, 0.01))
        func line(_ attributes: [NSAttributedString.Key: Any]) -> CTLine {
            let l = CTLineCreateWithAttributedString(NSAttributedString(string: caption, attributes: attributes))
            guard fullWidth > maxTextWidth else { return l }
            let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
            return CTLineCreateTruncatedLine(l, Double(maxTextWidth), .end, ellipsis) ?? l
        }
        let inkLine = line(ink), haloLine = line(outline)
        let textWidth = CGFloat(CTLineGetTypographicBounds(inkLine, nil, nil, nil))
        let rotated = CGSize(width: textWidth * cosT + textHeight * sinT + 2 * halo,
                             height: textWidth * sinT + textHeight * cosT + 2 * halo)
        let box = labelRect(for: rotated, shapeBounds: shapeBounds, imageSize: imageSize, gap: 6 * pixelsPerPoint)

        // The context is flipped (top-left origin): rotate about the box's centre, then flip back locally
        // so the glyphs stand upright.
        ctx.saveGState()
        ctx.translateBy(x: box.midX, y: box.midY)
        ctx.rotate(by: tilt)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineJoin(.round)
        let origin = CGPoint(x: -textWidth / 2, y: -textHeight / 2 + descent)
        ctx.textPosition = origin
        CTLineDraw(haloLine, ctx)
        ctx.textPosition = origin
        CTLineDraw(inkLine, ctx)
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
