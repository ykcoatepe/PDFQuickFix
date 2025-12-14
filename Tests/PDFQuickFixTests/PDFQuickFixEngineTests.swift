import XCTest
import PDFKit
@testable import PDFQuickFix

final class PDFQuickFixEngineTests: XCTestCase {
    private struct StubOCRCandidate: OCRTextCandidate {
        let string: String
        let boundingBox: CGRect

        func boundingBoxNormalized(for range: Range<String.Index>) -> CGRect? {
            boundingBox
        }
    }

    private struct StubOCRProvider: OCRProviding {
        let candidates: [OCRTextCandidate]

        func recognizeText(in image: CGImage, languages: [String]) throws -> [OCRTextCandidate] {
            candidates
        }
    }

    func testManualRedactionProducesBlackBox() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 200, height: 200))
        let manualRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let engine = PDFQuickFixEngine(options: QuickFixOptions(doOCR: false, dpi: 72, redactionPadding: 0), languages: ["en-US"])

        let outputURL = try engine.process(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [0: [manualRect]]
        )

        let originalData = try Data(contentsOf: inputURL)
        let processedData = try Data(contentsOf: outputURL)
        XCTAssertNotEqual(originalData, processedData, "Manual redactions should alter the output PDF data")
    }

    func testOCRTextLayerIsPresentWhenEnabled() throws {
        let secret = "SECRET123"
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 200, height: 200))
        let ocr = StubOCRProvider(candidates: [
            StubOCRCandidate(
                string: secret,
                // Normalized coordinates in Vision space (origin bottom-left)
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1)
            )
        ])

        let engine = PDFQuickFixEngine(
            options: QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0),
            languages: ["en-US"],
            ocrProvider: ocr
        )

        let result = try engine.processWithReport(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        let doc = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertFalse(doc.findString(secret, withOptions: []).isEmpty, "Expected searchable OCR text layer to contain the stubbed secret")
        XCTAssertEqual(result.redactionReport.pagesWithRedactions.count, 0)
        XCTAssertEqual(result.redactionReport.totalSuppressedOCRRunCount, 0)
    }

    func testManualRedactionSuppressesOverlappingOCRRuns() throws {
        let secret = "SECRET123"
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 200, height: 200))
        let manualRect = CGRect(x: 20, y: 20, width: 160, height: 20)
        let ocr = StubOCRProvider(candidates: [
            StubOCRCandidate(
                string: secret,
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1)
            )
        ])

        let engine = PDFQuickFixEngine(
            options: QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0),
            languages: ["en-US"],
            ocrProvider: ocr
        )

        let result = try engine.processWithReport(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [0: [manualRect]]
        )

        let doc = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertTrue(doc.findString(secret, withOptions: []).isEmpty, "Manual redaction must suppress searchable OCR runs that overlap redaction rectangles")
        XCTAssertEqual(result.redactionReport.pagesWithRedactions.count, 1)
        XCTAssertEqual(result.redactionReport.totalRedactionRectCount, 1)
        XCTAssertEqual(result.redactionReport.totalSuppressedOCRRunCount, 1)
        XCTAssertEqual(result.redactionReport.pagesWithRedactions.first?.pageIndex, 0)
    }

    func testRegexRedactionSuppressesOCR() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 200, height: 200))
        let secret = "123-45-6789"
        let ocr = StubOCRProvider(candidates: [
            StubOCRCandidate(
                string: "SSN \(secret)",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1)
            )
        ])

        let engine = PDFQuickFixEngine(
            options: QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0),
            languages: ["en-US"],
            ocrProvider: ocr
        )

        let result = try engine.processWithReport(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [
                RedactionPattern(name: "SSN", pattern: #"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)"#)
            ],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        let doc = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertTrue(doc.findString(secret, withOptions: []).isEmpty, "Regex redaction must suppress searchable OCR for the matched secret")
        XCTAssertEqual(result.redactionReport.pagesWithRedactions.count, 1)
    }

    func testReplacementRemainsSearchableOriginalIsNot() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 200, height: 200))
        let ocr = StubOCRProvider(candidates: [
            StubOCRCandidate(
                string: "John Doe",
                boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1)
            )
        ])

        let engine = PDFQuickFixEngine(
            options: QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0),
            languages: ["en-US"],
            ocrProvider: ocr
        )

        let result = try engine.processWithReport(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [FindReplaceRule(find: "John", replace: "J***")],
            manualRedactions: [:]
        )

        let doc = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertTrue(doc.findString("John", withOptions: []).isEmpty, "Original text must not remain searchable after replacement")
        XCTAssertFalse(doc.findString("J***", withOptions: []).isEmpty, "Replacement text should remain searchable")
        XCTAssertEqual(result.redactionReport.pagesWithRedactions.count, 0)
        XCTAssertEqual(result.redactionReport.totalSuppressedOCRRunCount, 0)
    }

    func testRotatedPageManualRedactionStillSuppressesOCR() throws {
        let originalURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 300, height: 200))
        let docToRotate = try XCTUnwrap(PDFDocument(url: originalURL))
        let pageToRotate = try XCTUnwrap(docToRotate.page(at: 0))
        pageToRotate.rotation = 90
        let rotatedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        XCTAssertTrue(docToRotate.write(to: rotatedURL))

        let secret = "SECRET123"
        let normalizedBox = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2)
        let ocr = StubOCRProvider(candidates: [
            StubOCRCandidate(string: secret, boundingBox: normalizedBox)
        ])

        let engine = PDFQuickFixEngine(
            options: QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0),
            languages: ["en-US"],
            ocrProvider: ocr
        )

        let rotatedDoc = try XCTUnwrap(PDFDocument(url: rotatedURL))
        let rotatedPage = try XCTUnwrap(rotatedDoc.page(at: 0))
        let cgPage = try XCTUnwrap(rotatedPage.pageRef)

        let renderBox: CGPDFBox = .mediaBox
        let sourceBox = cgPage.getBoxRect(renderBox)
        let rotationAngle = ((cgPage.rotationAngle % 360) + 360) % 360
        let pageSizePoints: CGSize = (rotationAngle == 90 || rotationAngle == 270)
            ? CGSize(width: sourceBox.height, height: sourceBox.width)
            : sourceBox.size
        let widthPx = max(1, Int(ceil(pointsToPixels(pageSizePoints.width, dpi: engine.options.dpi))))
        let heightPx = max(1, Int(ceil(pointsToPixels(pageSizePoints.height, dpi: engine.options.dpi))))
        let targetRectPx = CGRect(x: 0, y: 0, width: CGFloat(widthPx), height: CGFloat(heightPx))
        let pageToPixelTransform = cgPage.getDrawingTransform(renderBox,
                                                              rect: targetRectPx,
                                                              rotate: 0,
                                                              preserveAspectRatio: true)
        let pixelToPageTransform = pageToPixelTransform.inverted()
        let ocrRectPx = visionRectToPixelRect(normalizedBox, imageSize: CGSize(width: targetRectPx.width, height: targetRectPx.height))
        let manualRect = ocrRectPx.applying(pixelToPageTransform).standardized

        let result = try engine.processWithReport(
            inputURL: rotatedURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [0: [manualRect]]
        )

        let outDoc = try XCTUnwrap(PDFDocument(url: result.outputURL))
        XCTAssertTrue(outDoc.findString(secret, withOptions: []).isEmpty, "Rotation must not break manual redaction suppression of OCR")
        XCTAssertEqual(result.redactionReport.pagesWithRedactions.count, 1)
        XCTAssertEqual(result.redactionReport.totalRedactionRectCount, 1)
        XCTAssertEqual(result.redactionReport.totalSuppressedOCRRunCount, 1)
    }
}
