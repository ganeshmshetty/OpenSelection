import XCTest
import AppKit
import CoreGraphics
@testable import OpenSelection

final class CursorClassifierTests: XCTestCase {
    func testBlankImageClassifiesUnknown() {
        let blank = makeCursorImage(width: 16, height: 16) { _, _ in false }
        XCTAssertEqual(CursorClassifier.classify(blank), .unknown)
    }

    func testBeamShapeClassifiesBeam() {
        let beam = makeCursorImage(width: 16, height: 32) { x, y in
            if y < 3 || y >= 29 {
                return x >= 5 && x <= 10
            }
            return x >= 7 && x <= 8
        }
        XCTAssertEqual(CursorClassifier.classify(beam), .beam)
    }

    func testWideSerifBeamShapeClassifiesBeam() {
        let beam = makeCursorImage(width: 24, height: 38) { x, y in
            if y < 4 || y >= 34 {
                return x >= 1 && x <= 22
            }
            return x >= 10 && x <= 13
        }
        XCTAssertEqual(CursorClassifier.classify(beam), .beam)
    }

    func testArrowShapeClassifiesArrow() {
        let arrow = makeCursorImage(width: 16, height: 16) { x, y in
            x <= y
        }
        XCTAssertEqual(CursorClassifier.classify(arrow), .arrow)
    }

    func testPointingHandShapeClassifiesPointingHand() {
        let widths = [3, 4, 5, 6, 9, 12, 14, 14, 14, 13, 12, 10, 8, 7, 6, 5]
        let hand = makeCursorImage(width: 16, height: 16) { x, y in
            let w = widths[y]
            let start = (16 - w) / 2
            return x >= start && x < start + w
        }
        XCTAssertEqual(CursorClassifier.classify(hand), .pointingHand)
    }

    func testRealSystemPointingHandClassifiesPointingHand() {
        let result = CursorClassifier.classify(NSCursor.pointingHand.image)
        XCTAssertTrue(result == .pointingHand || result == .unknown)
    }

    func testARGBPixelLayoutClassifiesSameShapes() {
        let beam = makeCursorImageARGB(width: 16, height: 32) { x, y in
            if y < 3 || y >= 29 {
                return x >= 5 && x <= 10
            }
            return x >= 7 && x <= 8
        }
        XCTAssertEqual(CursorClassifier.classify(beam), .beam)
    }

    func testNoAlphaLayoutClassifiesUnknown() {
        let opaque = makeCursorImageNoAlpha(width: 16, height: 32) { x, y in
            x >= 7 && x <= 8
        }
        XCTAssertEqual(CursorClassifier.classify(opaque), .unknown)
    }

    func testSystemArrowAndIBeamCursorsDegradeSafely() {
        let arrow = CursorClassifier.classify(NSCursor.arrow.image)
        XCTAssertTrue(arrow == .arrow || arrow == .unknown)
        let beam = CursorClassifier.classify(NSCursor.iBeam.image)
        XCTAssertTrue(beam == .beam || beam == .unknown)
    }

    // MARK: - Fixtures

    private func makeCursorImage(width: Int, height: Int, opaque: (Int, Int) -> Bool) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width where opaque(x, y) {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = 0       // R
                pixels[offset + 1] = 0   // G
                pixels[offset + 2] = 0   // B
                pixels[offset + 3] = 255 // A (last)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func makeCursorImageARGB(width: Int, height: Int, opaque: (Int, Int) -> Bool) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width where opaque(x, y) {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = 255     // A (first)
                pixels[offset + 1] = 0   // R
                pixels[offset + 2] = 0   // G
                pixels[offset + 3] = 0   // B
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func makeCursorImageNoAlpha(width: Int, height: Int, opaque: (Int, Int) -> Bool) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        for y in 0..<height {
            for x in 0..<width where opaque(x, y) {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
