import AppKit
import CoreGraphics
import PDFKit
@testable import PDFQuickFix
import PDFQuickFixKit
import XCTest

final class PDFSanitizerAppearanceTests: XCTestCase {
    private var usesHostGuard: Bool {
        ProcessInfo.processInfo.environment["PDFQF_SANITIZE_TEST_STANDALONE"] != "1"
    }

    override func setUp() {
        super.setUp()
        if usesHostGuard { PDFQFInstallPDFPageGuard() }
    }

    func testPrivacyCleanKeepsAsymmetricPageUpright() throws {
        let source = try fixture(origin: .zero, rotation: 0, cropped: false)
        let output = try PDFDocumentSanitizer.sanitize(document: source, options: .from(profile: .privacyClean))
        let image = try renderOutput(try XCTUnwrap(output.dataRepresentation()))
        XCTAssertTrue(try isColor(image, at: CGPoint(x: 30, y: 85), channel: 1), "Upper green marker must remain upright")
        XCTAssertTrue(try isColor(image, at: CGPoint(x: 220, y: 25), channel: 2), "Lower blue marker must remain upright")
    }

    func testPrivacyCleanPreservesVisibleCropRotationAndAnnotationAfterSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for origin in [CGPoint.zero, CGPoint(x: -30, y: 40)] {
            for rotation in [0, 90, 180, 270] {
                let source = try fixture(origin: origin, rotation: rotation)
                let output = try PDFDocumentSanitizer.sanitize(document: source, options: .from(profile: .privacyClean))
                let url = directory.appendingPathComponent(UUID().uuidString + ".pdf")
                XCTAssertTrue(output.write(to: url))
                let data = try Data(contentsOf: url)
                let reopened = try XCTUnwrap(PDFDocument(data: data))
                let page = try XCTUnwrap(reopened.page(at: 0))
                let size = rotation % 180 == 0 ? CGSize(width: 280, height: 130) : CGSize(width: 130, height: 280)
                XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(origin: .zero, size: size))
                XCTAssertEqual(page.bounds(for: .cropBox), CGRect(origin: .zero, size: size))
                XCTAssertEqual(page.rotation, 0)
                XCTAssertTrue(page.annotations.isEmpty, "Visible annotations must be baked into privacy-clean pixels")
                let image = try renderOutput(data)
                XCTAssertTrue(try isColor(image, at: rotated(CGPoint(x: 30, y: 85), rotation: rotation), channel: 1))
                XCTAssertTrue(try isColor(image, at: rotated(CGPoint(x: 220, y: 25), rotation: rotation), channel: 2))
                let annotation = try pixel(image, at: rotated(CGPoint(x: 150, y: 55), rotation: rotation))
                XCTAssertGreaterThan(annotation[0], 180)
                XCTAssertLessThan(annotation[1], 80)
                XCTAssertGreaterThan(annotation[2], 180, "Visible annotation must survive the actual native page draw")
                for point in [CGPoint(x: 3, y: 3), CGPoint(x: size.width - 3, y: size.height - 3)] {
                    XCTAssertTrue(try pixel(image, at: point).prefix(3).allSatisfy { $0 > 240 }, "Red content outside CropBox must not be exposed")
                }
            }
        }
    }

    func testPrivacyCleanRejectsActualGuardFallbackWithoutPoisoningLaterDraw() throws {
        guard usesHostGuard else { throw XCTSkip("Standalone PDFKit mode has no host exception guard") }
        let document = try fixture(origin: .zero, rotation: 90)
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = SanitizerThrowingAnnotation(bounds: CGRect(x: 50, y: 200, width: 20, height: 20), forType: .square, withProperties: nil)
        page.addAnnotation(annotation)
        let failures = PDFQFPageDrawingFailureCount()
        XCTAssertThrowsError(try PDFDocumentSanitizer.sanitize(document: document, options: .from(profile: .privacyClean))) {
            guard case PDFDocumentSanitizerError.pageRenderFailed = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertGreaterThan(PDFQFPageDrawingFailureCount(), failures, "The actual Objective-C guard must have caught the forced appearance failure")
        XCTAssertTrue(page.annotations.contains { $0 === annotation })
        page.removeAnnotation(annotation)
        XCTAssertNoThrow(try PDFDocumentSanitizer.sanitize(document: document, options: .from(profile: .privacyClean)))
    }

    func testPrivacyCleanPreservesEachPagesOwnDisplayedSize() throws {
        let document = PDFDocument()
        for rotation in [0, 90, 180, 270] {
            let source = try fixture(origin: CGPoint(x: -30, y: 40), rotation: rotation)
            document.insert(try XCTUnwrap(source.page(at: 0)?.copy() as? PDFPage), at: document.pageCount)
        }
        let output = try PDFDocumentSanitizer.sanitize(document: document, options: .from(profile: .privacyClean))
        let data = try XCTUnwrap(output.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(reopened.pageCount, 4)
        for (index, rotation) in [0, 90, 180, 270].enumerated() {
            let page = try XCTUnwrap(reopened.page(at: index))
            let size = rotation % 180 == 0 ? CGSize(width: 280, height: 130) : CGSize(width: 130, height: 280)
            XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(origin: .zero, size: size))
            let image = try renderOutput(data, pageNumber: index + 1)
            XCTAssertTrue(try isColor(image, at: rotated(CGPoint(x: 30, y: 85), rotation: rotation), channel: 1))
        }
    }

    private func fixture(origin: CGPoint, rotation: Int, cropped: Bool = true) throws -> PDFDocument {
        var media = CGRect(origin: origin, size: CGSize(width: 320, height: 300))
        let crop = cropped ? CGRect(x: origin.x + 20, y: origin.y + 150, width: 280, height: 130) : media
        let bytes = NSMutableData()
        let context = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: bytes)), mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.red.cgColor); context.fill(media)
        context.setFillColor(NSColor.white.cgColor); context.fill(crop)
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(x: crop.minX + 10, y: crop.minY + 70, width: 40, height: 30))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: crop.minX + 200, y: crop.minY + 10, width: 40, height: 30))
        context.endPDFPage(); context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: bytes as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(crop, for: .cropBox)
        page.rotation = rotation
        let annotation = PDFAnnotation(bounds: CGRect(x: crop.minX + 135, y: crop.minY + 40, width: 30, height: 30), forType: .square, withProperties: nil)
        annotation.color = .magenta
        annotation.interiorColor = .magenta
        page.addAnnotation(annotation)
        return try XCTUnwrap(PDFDocument(data: PDFDocumentSerializer.data(from: document)))
    }

    private func rotated(_ point: CGPoint, rotation: Int) -> CGPoint {
        switch rotation {
        case 90: CGPoint(x: point.y, y: 280 - point.x)
        case 180: CGPoint(x: 280 - point.x, y: 130 - point.y)
        case 270: CGPoint(x: 130 - point.y, y: point.x)
        default: point
        }
    }

    private func renderOutput(_ data: Data, pageNumber: Int = 1) throws -> CGImage {
        let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
        let page = try XCTUnwrap(document.page(at: pageNumber))
        let box = page.getBoxRect(.mediaBox)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(box.width), height: Int(box.height), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1); context.fill(box)
        context.drawPDFPage(page)
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, at point: CGPoint) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0.5 - point.x, y: 0.5 - point.y)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func isColor(_ image: CGImage, at point: CGPoint, channel: Int) throws -> Bool {
        let bytes = try pixel(image, at: point)
        return (0 ..< 3).allSatisfy { $0 == channel ? bytes[$0] > 180 : bytes[$0] < 80 }
    }
}

private final class SanitizerThrowingAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        NSException(name: .internalInconsistencyException, reason: "Synthetic sanitizer annotation appearance failure", userInfo: nil).raise()
    }
}
