import AppKit
import CoreText
import PDFKit
@testable import PDFQuickFix
import Vision
import XCTest

@MainActor
final class RedactionRasterAlignmentTests: XCTestCase {
    func testVisionRectanglesCoverTopAndBottomRasterTargetsAtMultipleScales() throws {
        for scale: CGFloat in [1, 2] {
            let size = CGSize(width: 200 * scale, height: 300 * scale)
            for targetY: CGFloat in [40, 220] {
                let target = CGRect(x: 30 * scale, y: targetY * scale, width: 80 * scale, height: 20 * scale)
                let context = try bitmap(size: size)
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
                context.setFillColor(NSColor.red.cgColor)
                context.fill(target)
                let normalized = CGRect(x: target.minX / size.width, y: target.minY / size.height,
                                        width: target.width / size.width, height: target.height / size.height)
                context.setFillColor(NSColor.black.cgColor)
                context.fill(visionRectToPixelRect(normalized, imageSize: size))
                let image = try XCTUnwrap(context.makeImage())

                XCTAssertTrue(try isBlack(image, at: CGPoint(x: target.midX, y: target.midY)))
                let reflectedCenter = CGPoint(x: target.midX, y: size.height - target.midY)
                XCTAssertTrue(try isWhite(image, at: reflectedCenter), "The mirrored location must remain untouched")
            }
        }
    }

    func testVisionRegexRedactionCoversVisibleTextAndLeavesMirroredAreaUntouched() throws {
        let mediaBox = CGRect(x: 0, y: 0, width: 320, height: 300)
        let input = try makePDF(mediaBox: mediaBox) { context in
            for y: CGFloat in [55, 210] {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SYNTHETIC", attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 24, nil),
                ]))
                context.textPosition = CGPoint(x: 35, y: y)
                CTLineDraw(line, context)
            }
        }
        defer { try? FileManager.default.removeItem(at: input) }
        let original = try Data(contentsOf: input)
        let sourceImage = try render(try XCTUnwrap(PDFDocument(url: input)?.page(at: 0)))
        for dpi: CGFloat in [72, 144] {
            let output = temporaryURL()
            defer { try? FileManager.default.removeItem(at: output) }
            let engine = PDFQuickFixEngine(options: QuickFixOptions(doOCR: true, dpi: dpi, redactionPadding: 0,
                                                                    ocrProvider: .visionOnly), languages: ["en-US"],
                                          repairSourceURL: { $0 })
            let result = try engine.processResult(inputURL: input, outputURL: output, redactionPatterns: [],
                                                  customRegexes: [NSRegularExpression(pattern: "SYNTHETIC")])
            XCTAssertGreaterThanOrEqual(result.redactionReport.totalRedactionRectCount, 2, "Vision must detect both targets")
            let image = try render(try XCTUnwrap(PDFDocument(url: output)?.page(at: 0)))
            for y: CGFloat in [55, 210] {
                let interior = CGRect(x: 60, y: y + 6, width: 90, height: 4)
                XCTAssertLessThan(try blackFraction(sourceImage, in: interior), 0.9, "Fixture is visible text, not a solid box")
                XCTAssertGreaterThan(try blackFraction(image, in: interior), 0.98, "Black raster must cover the actual text position")
                XCTAssertTrue(try isWhite(image, at: CGPoint(x: 100, y: 300 - y - 8)), "Mirrored blank region must remain white")
            }
            XCTAssertEqual(try Data(contentsOf: input), original, "Processing must not change source bytes")
        }
    }

    func testManualPDFRectanglesKeepTheirCoordinatesAcrossPageOriginsAndScales() throws {
        for origin in [CGPoint.zero, CGPoint(x: -30, y: 40)] {
            let box = CGRect(origin: origin, size: CGSize(width: 200, height: 300))
            let target = CGRect(x: origin.x + 30, y: origin.y + 220, width: 80, height: 20)
            let input = try makePDF(mediaBox: box) { context in
                context.setFillColor(NSColor.red.cgColor)
                context.fill(target)
            }
            defer { try? FileManager.default.removeItem(at: input) }
            let original = try Data(contentsOf: input)
            for dpi: CGFloat in [72, 144] {
                let output = temporaryURL()
                defer { try? FileManager.default.removeItem(at: output) }
                let engine = PDFQuickFixEngine(options: QuickFixOptions(doOCR: false, dpi: dpi, redactionPadding: 0),
                                              repairSourceURL: { $0 })
                _ = try engine.process(inputURL: input, outputURL: output, redactionPatterns: [],
                                       manualRedactions: [0: [target]])
                let image = try render(try XCTUnwrap(PDFDocument(url: output)?.page(at: 0)))
                XCTAssertTrue(try isBlack(image, at: CGPoint(x: 70, y: 230)))
                XCTAssertTrue(try isWhite(image, at: CGPoint(x: 70, y: 70)))
                XCTAssertEqual(try Data(contentsOf: input), original)
            }
        }
    }

    func testProviderTopLeftRunsPlaceSearchableTextAtTheSameVisibleLocation() throws {
        let input = try makePDF(mediaBox: CGRect(x: 0, y: 0, width: 200, height: 300)) { _ in }
        defer { try? FileManager.default.removeItem(at: input) }
        for useCloud in [false, true] {
            let output = temporaryURL()
            defer { try? FileManager.default.removeItem(at: output) }
            let options = QuickFixOptions(doOCR: true, dpi: 144, ocrProvider: .autoLocalOCR,
                                          cloudOcrEnabled: useCloud, cloudOcrApiKey: useCloud ? "synthetic-test-key" : "")
            let engine = PDFQuickFixEngine(options: options,
                                          localOCRProvider: SyntheticLocalOCR(fails: useCloud),
                                          cloudOCRProvider: SyntheticCloudOCR(), repairSourceURL: { $0 })
            _ = try engine.process(inputURL: input, outputURL: output, redactionPatterns: [])
            let document = try XCTUnwrap(PDFDocument(url: output))
            let page = try XCTUnwrap(document.page(at: 0))
            let selection = try XCTUnwrap(document.findString("PROVIDER", withOptions: []).first)
            let bounds = selection.bounds(for: page)
            XCTAssertGreaterThan(bounds.midY, 240, "Provider y=40px from top belongs near the page top")
            XCTAssertLessThan(bounds.midY, 290)
            XCTAssertGreaterThan(bounds.minX, 15)
            XCTAssertLessThan(bounds.minX, 25)
        }
    }

    func testFindReplaceKeepsVisibleReplacementAtOriginalTextPosition() throws {
        let input = try makePDF(mediaBox: CGRect(x: 0, y: 0, width: 320, height: 300)) { context in
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "SYNTHETIC", attributes: [
                kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 24, nil),
            ]))
            context.textPosition = CGPoint(x: 35, y: 210)
            CTLineDraw(line, context)
        }
        let output = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        let original = try Data(contentsOf: input)
        let engine = PDFQuickFixEngine(options: QuickFixOptions(doOCR: true, dpi: 144, redactionPadding: 0,
                                                                ocrProvider: .visionOnly), languages: ["en-US"],
                                      repairSourceURL: { $0 })
        _ = try engine.process(inputURL: input, outputURL: output, redactionPatterns: [],
                               findReplace: [FindReplaceRule(find: "SYNTHETIC", replace: "PUBLIC")])
        let image = try render(try XCTUnwrap(PDFDocument(url: output)?.page(at: 0)))
        let observations = try VisionOCRProvider(languages: ["en-US"]).recognizeText(cgImage: image)
        let replacement = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string.contains("PUBLIC") == true })
        XCTAssertGreaterThan(replacement.boundingBox.midY, 0.65, "Visible replacement must remain near the original top text")
        XCTAssertLessThan(try blackFraction(image, in: CGRect(x: 60, y: 82, width: 90, height: 4)), 0.01)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    private func bitmap(size: CGSize) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func render(_ page: PDFPage) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let context = try bitmap(size: box.size)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: box.size))
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(try XCTUnwrap(page.pageRef))
        return try XCTUnwrap(context.makeImage())
    }

    private func color(_ image: CGImage, at point: CGPoint) throws -> [UInt8] {
        // Sample the image as drawn in Quartz coordinates, without assuming the
        // row order of its provider's bytes or introducing a second y conversion.
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                                 bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0.5 - point.x, y: 0.5 - point.y)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func isBlack(_ image: CGImage, at point: CGPoint) throws -> Bool {
        try color(image, at: point).prefix(3).allSatisfy { $0 < 16 }
    }

    private func isWhite(_ image: CGImage, at point: CGPoint) throws -> Bool {
        try color(image, at: point).prefix(3).allSatisfy { $0 > 240 }
    }

    private func blackFraction(_ image: CGImage, in rect: CGRect) throws -> Double {
        var black = 0
        for x in 0 ..< 10 {
            for y in 0 ..< 4 {
                let point = CGPoint(x: rect.minX + (CGFloat(x) + 0.5) * rect.width / 10,
                                    y: rect.minY + (CGFloat(y) + 0.5) * rect.height / 4)
                if try isBlack(image, at: point) { black += 1 }
            }
        }
        return Double(black) / 40
    }

    private func makePDF(mediaBox: CGRect, draw: (CGContext) -> Void) throws -> URL {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var box = mediaBox
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        draw(context)
        context.endPDFPage()
        context.closePDF()
        let url = temporaryURL()
        try data.write(to: url)
        return url
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
    }
}

private struct SyntheticLocalOCR: LocalOCRProviding {
    let fails: Bool
    func isAvailable() -> Bool { true }
    func recognizeTextLines(cgImage _: CGImage) throws -> [RecognizedRun] {
        if fails { throw NSError(domain: "SyntheticLocalOCR", code: 1) }
        return [RecognizedRun(kind: .keep("PROVIDER"), rectInPixels: CGRect(x: 40, y: 40, width: 200, height: 40))]
    }
}

private struct SyntheticCloudOCR: CloudOCRProviding {
    func recognizeTextLines(cgImage _: CGImage) throws -> [RecognizedRun] {
        [RecognizedRun(kind: .keep("PROVIDER"), rectInPixels: CGRect(x: 40, y: 40, width: 200, height: 40))]
    }
}
