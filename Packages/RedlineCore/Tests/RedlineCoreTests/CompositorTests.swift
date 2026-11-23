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

private func isDark(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool { p.r < 60 && p.g < 60 && p.b < 60 }

@Test func captionedAIMarkDrawsALabelBelowTheShape() throws {
    let wide = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 100), scale: 2)
    let box = CGRect(x: 10, y: 10, width: 40, height: 20)   // pixels (20,20)-(100,60)
    let plain = try #require(AnnotationCompositor.compose(image: whiteImage(400, 200), display: wide,
                                                           annotations: [aiBox(box, caption: nil)]))
    let out = try #require(AnnotationCompositor.compose(image: whiteImage(400, 200), display: wide,
                                                         annotations: [aiBox(box, caption: "Save button")]))
    #expect(out.width == 400 && out.height == 200)
    // The label starts 12 px below the shape (y ≈ 72) at x = 20, with a 6 px blue accent on its left.
    let accent = rgb(out, 23, 85)
    #expect(accent.b > 200 && accent.r < 60)
    let dark = (30..<140).filter { isDark(rgb(out, $0, 75)) }
    #expect(dark.count > 40)
    #expect((30..<140).allSatisfy { rgb(plain, $0, 75).r > 250 })   // no label without a caption
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
    // No room below, so the label goes above the shape (pixels 88-96), trimmed to the image width.
    #expect(rgb(out, 2, 60).b > 200)                       // blue accent at the left edge
    #expect((8..<40).contains { isDark(rgb(out, $0, 60)) })
    #expect(!(0..<100).contains { isDark(rgb(out, $0, 98)) })
}
