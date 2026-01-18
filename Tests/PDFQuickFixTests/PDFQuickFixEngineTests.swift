import XCTest
import PDFKit
@testable import PDFQuickFix

final class PDFQuickFixEngineTests: XCTestCase {
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

    func testQuickFixOutputHasNonZeroMediaBox() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "Hello", size: CGSize(width: 200, height: 200))
        let engine = PDFQuickFixEngine(options: QuickFixOptions(doOCR: false, dpi: 72, redactionPadding: 0), languages: ["en-US"])

        let outputURL = try engine.process(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        guard let outDoc = PDFDocument(url: outputURL),
              let outPage = outDoc.page(at: 0) else {
            XCTFail("Unable to load processed PDF")
            return
        }

        let bounds = outPage.bounds(for: .mediaBox)
        XCTAssertGreaterThan(bounds.width, 0, "Output page MediaBox width should be non-zero")
        XCTAssertGreaterThan(bounds.height, 0, "Output page MediaBox height should be non-zero")
        XCTAssertNotNil(outPage.pageRef, "Output page should have a CGPDFPage backing reference")
    }
}
