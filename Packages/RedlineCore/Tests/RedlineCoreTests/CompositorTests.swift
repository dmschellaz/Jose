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
