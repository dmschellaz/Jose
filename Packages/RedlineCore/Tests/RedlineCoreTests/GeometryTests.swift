import Testing
import Foundation
import CoreGraphics
@testable import RedlineCore

private let retina = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2)
private let leftExternal = DisplayGeometry(id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), scale: 1)

@Test func globalToPixelOnRetina() {
    #expect(CoordinateMapper.pixel(fromGlobal: CGPoint(x: 100, y: 50), on: retina) == CGPoint(x: 200, y: 100))
}

@Test func globalToPixelOnNegativeOriginDisplay() {
    let p = CoordinateMapper.pixel(fromGlobal: CGPoint(x: -1900, y: -100), on: leftExternal)
    #expect(p == CGPoint(x: 20, y: 100))
}

@Test func pixelRoundTrip() {
    let g = CGPoint(x: -1000.5, y: 300.25)
    let back = CoordinateMapper.global(fromPixel: CoordinateMapper.pixel(fromGlobal: g, on: leftExternal), on: leftExternal)
    #expect(back == g)
}

@Test func downscaledImageRoundTrip() {
    let size = CGSize(width: 1280, height: 831.3)
    let g = CGPoint(x: 756, y: 491)
    let ip = CoordinateMapper.imagePoint(fromGlobal: g, imageSize: size, on: retina)
    #expect(abs(ip.x - 640) < 0.001)
    let back = CoordinateMapper.global(fromImagePoint: ip, imageSize: size, on: retina)
    #expect(abs(back.x - g.x) < 0.001 && abs(back.y - g.y) < 0.001)
}

@Test func localAndGlobal() {
    #expect(CoordinateMapper.local(fromGlobal: CGPoint(x: -1820, y: 0), on: leftExternal) == CGPoint(x: 100, y: 200))
    #expect(CoordinateMapper.global(fromLocal: CGPoint(x: 100, y: 200), on: leftExternal) == CGPoint(x: -1820, y: 0))
}

@Test func cocoaToQuartzFlipsAgainstPrimaryHeight() {
    #expect(CoordinateMapper.quartz(fromCocoa: CGPoint(x: 10, y: 982), primaryHeight: 982) == CGPoint(x: 10, y: 0))
}

@Test func displayContainingPoint() {
    #expect(CoordinateMapper.display(containing: CGPoint(x: -5, y: 0), in: [retina, leftExternal])?.id == 2)
    #expect(CoordinateMapper.display(containing: CGPoint(x: 5, y: 5), in: [retina, leftExternal])?.id == 1)
    #expect(CoordinateMapper.display(containing: CGPoint(x: 9999, y: 0), in: [retina, leftExternal]) == nil)
}

@Test func shapeMappingScalesRadiusAndRects() {
    let double: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * 2, y: $0.y * 2) }
    #expect(AnnotationShape.circle(center: CGPoint(x: 1, y: 2), radius: 3).mapped(double, lengthScale: 2)
            == .circle(center: CGPoint(x: 2, y: 4), radius: 6))
    #expect(AnnotationShape.rect(CGRect(x: 1, y: 1, width: 2, height: 3)).mapped(double, lengthScale: 2)
            == .rect(CGRect(x: 2, y: 2, width: 4, height: 6)))
    #expect(AnnotationShape.stroke([CGPoint(x: 1, y: 1)]).mapped(double, lengthScale: 2) == .stroke([CGPoint(x: 2, y: 2)]))
}

@Test func annotationCodableRoundTrip() throws {
    let a = Annotation(id: UUID(), shape: .arrow(from: .zero, to: CGPoint(x: 5, y: 5)), caption: "this", author: .ai, createdAt: 3.5, displayID: 1)
    let data = try JSONEncoder().encode(a)
    #expect(try JSONDecoder().decode(Annotation.self, from: data) == a)
}
