import CoreGraphics
import Testing
@testable import Olaz

/// Thumbnails are redrawn once in the screen's color space and BGRA layout, so Core Animation shows them without keeping a
/// converted copy of each.
@Suite(.serialized) struct MediaDisplayReadyTests {
    private func image(space: CGColorSpace, alpha: CGImageAlphaInfo, order: CGBitmapInfo = []) -> CGImage {
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: order.rawValue | alpha.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        return ctx.makeImage()!
    }

    @Test func convertsToScreenSpaceAndBGRA() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        MediaLoader.setDisplayColorSpace(p3)
        defer { MediaLoader.setDisplayColorSpace(nil) }
        let out = MediaLoader.displayReady(image(space: CGColorSpace(name: CGColorSpace.sRGB)!, alpha: .noneSkipFirst))
        #expect(out.colorSpace == p3)
        #expect(out.width == 40 && out.height == 30)
        #expect(out.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little)
        #expect(out.alphaInfo == .noneSkipFirst)
    }

    @Test func keepsTransparency() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        MediaLoader.setDisplayColorSpace(space)
        defer { MediaLoader.setDisplayColorSpace(nil) }
        let out = MediaLoader.displayReady(image(space: space, alpha: .premultipliedLast))
        #expect(out.alphaInfo == .premultipliedFirst)
    }

    @Test func readyImagesAndUnknownScreenAreLeftAlone() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ready = image(space: space, alpha: .premultipliedFirst, order: .byteOrder32Little)
        MediaLoader.setDisplayColorSpace(space)
        #expect(MediaLoader.displayReady(ready) === ready)
        MediaLoader.setDisplayColorSpace(nil)
        let other = image(space: space, alpha: .noneSkipLast)
        #expect(MediaLoader.displayReady(other) === other)
    }
}
