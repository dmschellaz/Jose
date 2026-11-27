import Testing
import CoreGraphics
import Foundation
@testable import RedlineCore

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func whiteImage(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// RGB at (x, y) with y measured from the TOP of the image.
private func rgb(_ img: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    var bytes = [UInt8](repeating: 0, count: img.width * img.height * 4)
    bytes.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8,
                            bytesPerRow: img.width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    let i = (y * img.width + x) * 4
    return (bytes[i], bytes[i + 1], bytes[i + 2])
}

private let display = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 50, height: 50), scale: 2)

private func rect(_ r: CGRect, display id: UInt32 = 1) -> Annotation {
    Annotation(shape: .rect(r), caption: nil, author: .user, createdAt: 0, displayID: id)
}

@Test func rectIsDrawnAtPixelCoordinates() throws {
    let out = try #require(AnnotationCompositor.compose(image: whiteImage(100, 100), display: display,
                                                         annotations: [rect(CGRect(x: 10, y: 10, width: 10, height: 10))]))
    let edge = rgb(out, 20, 30)      // left edge of pixel rect (20,20)-(40,40)
    #expect(edge.r > 200 && edge.g < 140)
    let inside = rgb(out, 30, 30)
    #expect(inside.r > 250 && inside.g > 250)
}

@Test func originIsTopLeft() throws {
    let out = try #require(AnnotationCompositor.compose(image: whiteImage(100, 100), display: display,
                                                         annotations: [rect(CGRect(x: 10, y: 2, width: 10, height: 10))]))
    #expect(rgb(out, 30, 4).g < 140)    // top edge near the top
    #expect(rgb(out, 30, 95).g > 250)   // nothing near the bottom
}

@Test func annotationsOnOtherDisplaysAreIgnored() throws {
    let out = try #require(AnnotationCompositor.compose(image: whiteImage(100, 100), display: display,
                                                         annotations: [rect(CGRect(x: 10, y: 10, width: 10, height: 10), display: 2)]))
    #expect(rgb(out, 20, 30).g > 250)
}

@Test func pngAndJPEGRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    try ImageFiles.writePNG(whiteImage(64, 32), to: url)
    let loaded = try #require(ImageFiles.load(url))
    #expect(loaded.width == 64 && loaded.height == 32)
    #expect(ImageFiles.downscaled(loaded, maxWidth: 32).width == 32)
    #expect(ImageFiles.downscaled(loaded, maxWidth: 100).width == 64)
    let jpeg = try #require(ImageFiles.jpegData(loaded, maxWidth: 16))
    #expect(jpeg.starts(with: [0xFF, 0xD8]))
}

private func aiBox(_ r: CGRect, caption: String?) -> Annotation {
    Annotation(shape: .rect(r), caption: caption, author: .ai, createdAt: 0, displayID: 1)
}

/// AI blue: strongly blue, little red.
private func isBlue(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool { p.b > 180 && p.r < 120 }
private func isWhite(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool { p.r > 240 && p.g > 240 && p.b > 240 }

private func blackImage(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

private func count(_ img: CGImage, xs: Range<Int>, ys: Range<Int>, _ match: ((r: UInt8, g: UInt8, b: UInt8)) -> Bool) -> Int {
    var n = 0
    for y in ys { for x in xs where match(rgb(img, x, y)) { n += 1 } }
    return n
}

@Test func captionedAIMarkDrawsAHandwrittenCaptionBelowTheShape() throws {
    let wide = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2)
    let box = CGRect(x: 10, y: 10, width: 40, height: 20)   // pixels (20,20)-(100,60)
    let plain = try #require(AnnotationCompositor.compose(image: whiteImage(400, 200), display: wide,
                                                           annotations: [aiBox(box, caption: nil)]))
    let out = try #require(AnnotationCompositor.compose(image: whiteImage(400, 200), display: wide,
                                                         annotations: [aiBox(box, caption: "Save button")]))
    #expect(out.width == 400 && out.height == 200)
    // Blue ink below the shape (it starts 12 px below, y ≈ 72), and none there without a caption.
    #expect(count(out, xs: 20..<300, ys: 72..<150, isBlue) > 150)
    #expect(count(plain, xs: 20..<300, ys: 72..<150, isBlue) == 0)
    // No dark box any more: the caption is ink on the page.
    #expect(count(out, xs: 20..<300, ys: 72..<150) { $0.r < 60 && $0.g < 60 && $0.b < 60 } == 0)
}

@Test func captionHasAWhiteHaloOnDarkBackgrounds() throws {
    let wide = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2)
    let out = try #require(AnnotationCompositor.compose(image: blackImage(400, 200), display: wide,
                                                         annotations: [aiBox(CGRect(x: 10, y: 10, width: 40, height: 20), caption: "Save button")]))
    #expect(count(out, xs: 20..<300, ys: 72..<150, isWhite) > 100)
    #expect(count(out, xs: 20..<300, ys: 72..<150, isBlue) > 100)
}

@Test func aiRectIsSketchedAroundTheShape() throws {
    let wide = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2)
    let a = aiBox(CGRect(x: 40, y: 20, width: 100, height: 50), caption: nil)   // pixels (80,40)-(280,140)
    let out = try #require(AnnotationCompositor.compose(image: whiteImage(400, 200), display: wide, annotations: [a]))
    // Ink near each side, the middle untouched.
    #expect(count(out, xs: 150..<210, ys: 30..<50, isBlue) > 0)
    #expect(count(out, xs: 150..<210, ys: 130..<150, isBlue) > 0)
    #expect(count(out, xs: 70..<90, ys: 70..<110, isBlue) > 0)
    #expect(count(out, xs: 270..<290, ys: 70..<110, isBlue) > 0)
    #expect(count(out, xs: 110..<250, ys: 60..<120, isBlue) == 0)
    // Same annotation, same pixels: the seed comes from its id.
    let again = try #require(AnnotationCompositor.compose(image: whiteImage(400, 200), display: wide, annotations: [a]))
    #expect(out.dataProvider?.data == again.dataProvider?.data)
}

@Test func aiHighlightTintsTheRect() throws {
    let wide = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2)
    let a = Annotation(shape: .highlight(CGRect(x: 20, y: 20, width: 120, height: 20)), caption: nil, author: .ai, createdAt: 0, displayID: 1)
    let out = try #require(AnnotationCompositor.compose(image: whiteImage(400, 200), display: wide, annotations: [a]))
    // Pixels (40,40)-(280,80): mostly yellow-tinted (blue channel pulled down), still light.
    let tinted = count(out, xs: 50..<270, ys: 45..<75) { $0.b < 200 && $0.r > 240 }
    #expect(Double(tinted) > 0.9 * 220 * 30)
    #expect(count(out, xs: 0..<400, ys: 120..<200) { $0.b < 250 } == 0)
}

@Test func labelRectSitsBelowTheShape() {
    let r = AnnotationCompositor.labelRect(for: CGSize(width: 50, height: 10),
                                           shapeBounds: CGRect(x: 20, y: 20, width: 30, height: 30),
                                           imageSize: CGSize(width: 200, height: 200), gap: 6)
    #expect(r == CGRect(x: 20, y: 56, width: 50, height: 10))
}

@Test func labelRectFlipsAboveAtTheBottomEdge() {
    let r = AnnotationCompositor.labelRect(for: CGSize(width: 50, height: 10),
                                           shapeBounds: CGRect(x: 20, y: 170, width: 30, height: 25),
                                           imageSize: CGSize(width: 200, height: 200), gap: 6)
    #expect(r == CGRect(x: 20, y: 154, width: 50, height: 10))
}

@Test func labelRectIsClampedInsideTheImage() {
    let size = CGSize(width: 100, height: 60)
    let right = AnnotationCompositor.labelRect(for: CGSize(width: 40, height: 10),
                                               shapeBounds: CGRect(x: 90, y: 5, width: 5, height: 5), imageSize: size)
    #expect(right.minX == 60 && right.maxX == 100)
    let offTopLeft = AnnotationCompositor.labelRect(for: CGSize(width: 40, height: 10),
                                                    shapeBounds: CGRect(x: -30, y: -50, width: 10, height: 10), imageSize: size)
    #expect(offTopLeft.minX == 0 && offTopLeft.minY == 0)
    // Shape fills the whole height: no room above or below, but the label stays inside.
    let tall = AnnotationCompositor.labelRect(for: CGSize(width: 40, height: 10),
                                              shapeBounds: CGRect(x: 10, y: 0, width: 10, height: 60), imageSize: size)
    #expect(tall.minY >= 0 && tall.maxY <= 60)
    // Wider than the image: trimmed to fit.
    let huge = AnnotationCompositor.labelRect(for: CGSize(width: 500, height: 10),
                                              shapeBounds: CGRect(x: 10, y: 10, width: 10, height: 10), imageSize: size)
    #expect(huge == CGRect(x: 0, y: 26, width: 100, height: 10))
}

@Test func longCaptionNearTheCornerStaysInTheImage() throws {
    let out = try #require(AnnotationCompositor.compose(image: whiteImage(100, 100), display: display,
                                                         annotations: [aiBox(CGRect(x: 44, y: 44, width: 4, height: 4),
                                                                             caption: "a very long caption that cannot possibly fit")]))
    #expect(out.width == 100 && out.height == 100)
    // No room below, so the caption goes above the shape (pixels 88-96), trimmed to the image width.
    #expect(count(out, xs: 0..<100, ys: 30..<84, isBlue) > 40)
}
