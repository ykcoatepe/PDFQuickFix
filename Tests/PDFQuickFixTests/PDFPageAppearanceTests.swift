import AppKit
import CoreText
import PDFKit
@testable import PDFQuickFix
import PDFQuickFixKit
import Vision
import XCTest

final class PDFPageAppearanceTests: XCTestCase {
    func testQuickFixAndFlattenPreserveVisibleCropAcrossOriginsRotationsAndSupportedDPI() throws {
        for origin in [CGPoint.zero, CGPoint(x: -30, y: 40)] {
            for rotation in [0, 90, 180, 270] {
                let input = try fixture(origin: origin, rotation: rotation)
                defer { try? FileManager.default.removeItem(at: input) }
                let source = try XCTUnwrap(PDFDocument(url: input))
                let sourcePage = try XCTUnwrap(source.page(at: 0))
                let crop = sourcePage.bounds(for: .cropBox)
                let expectedSize = rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
                // Interior colored markers make clipping, reflection and off-crop disclosure observable.
                let green = rotated(CGPoint(x: 30, y: 85), size: crop.size, rotation: rotation)
                let blue = rotated(CGPoint(x: 220, y: 25), size: crop.size, rotation: rotation)
                let flattened = try XCTUnwrap(PDFDocument(data: PDFOps.flattenedData(document: source)))
                let flatPage = try XCTUnwrap(flattened.page(at: 0))
                XCTAssertEqual(flatPage.bounds(for: .mediaBox).size, expectedSize)
                let flatImage = try render(flatPage)
                XCTAssertTrue(try isGreen(flatImage, at: green))
                XCTAssertTrue(try isBlue(flatImage, at: blue))
                XCTAssertEqual(try redSampleCount(flatImage), 0, "The red area outside CropBox must never become visible")

                for dpi: CGFloat in [150, 200, 300, 600] {
                    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                    defer { try? FileManager.default.removeItem(at: output) }
                    let engine = PDFQuickFixEngine(options: QuickFixOptions(doOCR: false, dpi: dpi, redactionPadding: 0),
                                                  repairSourceURL: { $0 })
                    let target = CGRect(x: crop.minX + 10, y: crop.minY + 70, width: 40, height: 30)
                    _ = try engine.processResult(inputURL: input, outputURL: output, redactionPatterns: [],
                                                  manualRedactions: [0: [target]])
                    let outputDocument = try XCTUnwrap(PDFDocument(url: output))
                    let outputPage = try XCTUnwrap(outputDocument.page(at: 0))
                    XCTAssertEqual(outputPage.bounds(for: .mediaBox).size, expectedSize)
                    let image = try render(outputPage)
                    XCTAssertTrue(try isBlack(image, at: green), "Manual redaction missed at rotation \(rotation), DPI \(dpi)")
                    XCTAssertTrue(try isBlue(image, at: blue), "Unedited visible content must survive")
                    XCTAssertEqual(try redSampleCount(image), 0)
                }
            }
        }
    }

    func testFlattenRemapsOutlineDestinationAndRestoresHelpersEvenWhenRejected() throws {
        let input = try fixture(origin: CGPoint(x: -30, y: 40), rotation: 90)
        defer { try? FileManager.default.removeItem(at: input) }
        let document = try XCTUnwrap(PDFDocument(url: input))
        let page = try XCTUnwrap(document.page(at: 0))
        let crop = page.bounds(for: .cropBox)
        let helper = SelectionAnnotation(bounds: CGRect(x: crop.minX + 50, y: crop.minY + 50, width: 30, height: 30),
                                         forType: .square, withProperties: nil)
        helper.shouldPrint = false
        page.addAnnotation(helper)
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Marker"
        chapter.destination = PDFDestination(page: page, at: CGPoint(x: crop.minX + 30, y: crop.minY + 85))
        root.insertChild(chapter, at: 0)
        document.outlineRoot = root
        let output = try XCTUnwrap(PDFDocument(data: PDFOps.flattenedData(document: document)))
        XCTAssertTrue(page.annotations.contains { $0 === helper })
        let destination = try XCTUnwrap(output.outlineRoot?.child(at: 0)?.destination)
        XCTAssertEqual(destination.point.x, 85, accuracy: 0.5)
        XCTAssertEqual(destination.point.y, crop.width - 30, accuracy: 0.5)
        XCTAssertTrue(destination.page === output.page(at: 0))
        XCTAssertTrue(try XCTUnwrap(output.page(at: 0)).annotations.isEmpty)

        chapter.destination = nil
        chapter.action = PDFActionRemoteGoTo(pageIndex: 0, at: .zero, fileURL: URL(fileURLWithPath: "/synthetic/remote.pdf"))
        XCTAssertThrowsError(try PDFOps.flattenedData(document: document))
        XCTAssertTrue(page.annotations.contains { $0 === helper }, "Failure must restore the live selection")
    }

    func testFlattenPreservesUnspecifiedOutlineCoordinatesOnTheRotatedAxisAfterReopen() throws {
        let unspecified = kPDFDestinationUnspecifiedValue
        for rotation in [0, 90, 180, 270] {
            let input = try fixture(origin: CGPoint(x: -30, y: 40), rotation: rotation)
            defer { try? FileManager.default.removeItem(at: input) }
            let document = try XCTUnwrap(PDFDocument(url: input))
            let page = try XCTUnwrap(document.page(at: 0))
            let crop = page.bounds(for: .cropBox)
            let sourcePoints = [CGPoint(x: crop.minX + 30, y: crop.minY + 85),
                                CGPoint(x: unspecified, y: crop.minY + 85),
                                CGPoint(x: crop.minX + 30, y: unspecified),
                                CGPoint(x: unspecified, y: unspecified)]
            let expected: [CGPoint] = switch rotation {
            case 90: [CGPoint(x: 85, y: 250), CGPoint(x: 85, y: unspecified),
                      CGPoint(x: unspecified, y: 250), CGPoint(x: unspecified, y: unspecified)]
            case 180: [CGPoint(x: 250, y: 45), CGPoint(x: unspecified, y: 45),
                       CGPoint(x: 250, y: unspecified), CGPoint(x: unspecified, y: unspecified)]
            case 270: [CGPoint(x: 45, y: 30), CGPoint(x: 45, y: unspecified),
                       CGPoint(x: unspecified, y: 30), CGPoint(x: unspecified, y: unspecified)]
            default: [CGPoint(x: 30, y: 85), CGPoint(x: unspecified, y: 85),
                      CGPoint(x: 30, y: unspecified), CGPoint(x: unspecified, y: unspecified)]
            }
            let root = PDFOutline()
            for (index, point) in sourcePoints.enumerated() {
                let child = PDFOutline()
                child.label = "Destination \(index)"
                child.destination = PDFDestination(page: page, at: point)
                child.destination?.zoom = 1.25
                root.insertChild(child, at: index)
            }
            document.outlineRoot = root
            let output = try XCTUnwrap(PDFDocument(data: PDFOps.flattenedData(document: document)))
            XCTAssertEqual(output.outlineRoot?.numberOfChildren, sourcePoints.count)
            for (index, expectedPoint) in expected.enumerated() {
                let destination = try XCTUnwrap(output.outlineRoot?.child(at: index)?.destination)
                XCTAssertEqual(destination.point.x, expectedPoint.x, accuracy: 0.5, "rotation \(rotation), destination \(index)")
                XCTAssertEqual(destination.point.y, expectedPoint.y, accuracy: 0.5, "rotation \(rotation), destination \(index)")
                XCTAssertTrue(destination.page === output.page(at: 0))
                XCTAssertEqual(destination.zoom, 1.25)
                XCTAssertEqual(root.child(at: index)?.destination?.point, sourcePoints[index], "Source destination must remain untouched")
            }
        }
    }

    func testFlattenOmitsSelectionAppearanceButKeepsOrdinaryNonPrintingAnnotations() throws {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
        document.insert(page, at: 0)
        let helper = SelectionAnnotation(bounds: CGRect(x: 20, y: 20, width: 50, height: 50), forType: .square, withProperties: nil)
        helper.shouldPrint = false
        let visible = PDFAnnotation(bounds: CGRect(x: 110, y: 110, width: 50, height: 50), forType: .square, withProperties: nil)
        visible.color = .green
        visible.interiorColor = .green
        visible.shouldPrint = false
        page.addAnnotation(helper)
        page.addAnnotation(visible)
        let output = try XCTUnwrap(PDFDocument(data: PDFOps.flattenedData(document: document)))
        let image = try render(try XCTUnwrap(output.page(at: 0)))
        XCTAssertTrue(try isWhite(image, at: CGPoint(x: 20, y: 20)))
        XCTAssertTrue(try isGreen(image, at: CGPoint(x: 130, y: 130)))
        XCTAssertTrue(page.annotations.contains { $0 === helper })
        XCTAssertTrue(page.annotations.contains { $0 === visible })
    }

    func testWatermarkHasCompleteRotatedTranslucentAppearanceAfterSerializationAndCopy() throws {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 400, height: 400), for: .mediaBox)
        document.insert(page, at: 0)
        PDFOps.applyWatermark(document: document, text: "AUDIT COPY", fontSize: 42, color: .red, opacity: 0.25,
                              rotation: -30, position: .center, margin: 24)
        let copiedDocument = PDFDocument()
        copiedDocument.insert(try XCTUnwrap(page.copy() as? PDFPage), at: 0)
        for candidate in [document, copiedDocument] {
            let output = try XCTUnwrap(PDFDocument(data: PDFDocumentSerializer.data(from: candidate)))
            let image = try render(try XCTUnwrap(output.page(at: 0)), scale: 2)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var left = 0, right = 0
            var minX = image.width, maxX = 0, minY = image.height, maxY = 0
            var greenTotal: CGFloat = 0
            var count = 0
            for y in 0 ..< image.height {
                for x in 0 ..< image.width {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.redComponent > 0.95, color.greenComponent < 0.85, color.blueComponent < 0.85 {
                        if x < image.width / 2 { left += 1 } else { right += 1 }
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                        greenTotal += color.greenComponent
                        count += 1
                    }
                }
            }
            XCTAssertGreaterThan(left, 300)
            XCTAssertGreaterThan(right, 300, "The second word must render, not just AUDIT")
            XCTAssertGreaterThan(maxX - minX, 300)
            XCTAssertGreaterThan(maxY - minY, 150, "The watermark must be rotated")
            XCTAssertGreaterThan(greenTotal / CGFloat(max(count, 1)), 0.70, "25% opacity must remain translucent")
            XCTAssertLessThan(greenTotal / CGFloat(max(count, 1)), 0.85)
        }
    }

    func testCaughtNativeAppearanceFailureCannotPublishAFlattenedPageAndRestoresSelection() throws {
        let input = try fixture(origin: .zero, rotation: 90)
        defer { try? FileManager.default.removeItem(at: input) }
        let document = try XCTUnwrap(PDFDocument(url: input))
        let page = try XCTUnwrap(document.page(at: 0))
        let helper = SelectionAnnotation(bounds: CGRect(x: 40, y: 180, width: 30, height: 30), forType: .square, withProperties: nil)
        let broken = ThrowingAppearanceAnnotation(bounds: CGRect(x: 80, y: 180, width: 30, height: 30), forType: .square, withProperties: nil)
        page.addAnnotation(helper)
        page.addAnnotation(broken)
        // The application installs the real Objective-C guard before drawing.
        PDFQFInstallPDFPageGuard()
        XCTAssertThrowsError(try PDFOps.flattenedData(document: document)) { error in
            XCTAssertTrue(error is PDFPageRenderingError)
        }
        XCTAssertTrue(page.annotations.contains { $0 === helper })
        XCTAssertTrue(page.annotations.contains { $0 === broken })
        page.removeAnnotation(broken)
        XCTAssertNoThrow(try PDFOps.flattenedData(document: document), "A previous failure must not poison a later complete draw")
    }

    private func fixture(origin: CGPoint, rotation: Int) throws -> URL {
        var media = CGRect(origin: origin, size: CGSize(width: 320, height: 300))
        let crop = CGRect(x: origin.x + 20, y: origin.y + 150, width: 280, height: 130)
        let data = NSMutableData()
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.red.cgColor); context.fill(media)
        context.setFillColor(NSColor.white.cgColor); context.fill(crop)
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(x: crop.minX + 10, y: crop.minY + 70, width: 40, height: 30))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: crop.minX + 200, y: crop.minY + 10, width: 40, height: 30))
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(crop, for: .cropBox)
        page.rotation = rotation
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try PDFDocumentSerializer.data(from: document).write(to: url)
        return url
    }

    private func rotated(_ point: CGPoint, size: CGSize, rotation: Int) -> CGPoint {
        switch rotation {
        case 90: CGPoint(x: point.y, y: size.width - point.x)
        case 180: CGPoint(x: size.width - point.x, y: size.height - point.y)
        case 270: CGPoint(x: size.height - point.y, y: point.x)
        default: point
        }
    }

    private func render(_ page: PDFPage, scale: CGFloat = 1) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                             bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, at point: CGPoint) throws -> [UInt8] {
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

    private func isBlack(_ image: CGImage, at point: CGPoint) throws -> Bool { try pixel(image, at: point).prefix(3).allSatisfy { $0 < 20 } }
    private func isWhite(_ image: CGImage, at point: CGPoint) throws -> Bool { try pixel(image, at: point).prefix(3).allSatisfy { $0 > 240 } }
    private func isGreen(_ image: CGImage, at point: CGPoint) throws -> Bool {
        let c = try pixel(image, at: point); return c[1] > 180 && c[0] < 80 && c[2] < 80
    }
    private func isBlue(_ image: CGImage, at point: CGPoint) throws -> Bool {
        let c = try pixel(image, at: point); return c[2] > 180 && c[0] < 80 && c[1] < 80
    }
    private func redSampleCount(_ image: CGImage) throws -> Int {
        var count = 0
        for x in 0 ..< 10 { for y in 0 ..< 10 {
            let c = try pixel(image, at: CGPoint(x: (CGFloat(x) + 0.5) * CGFloat(image.width) / 10,
                                                y: (CGFloat(y) + 0.5) * CGFloat(image.height) / 10))
            if c[0] > 200, c[1] < 50, c[2] < 50 { count += 1 }
        } }
        return count
    }
}

private final class ThrowingAppearanceAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        NSException(name: .internalInconsistencyException, reason: "Synthetic annotation appearance failure", userInfo: nil).raise()
    }
}
