import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import PDFQuickFix

final class DocumentTextSessionTests: XCTestCase {
    func testParsePageSelectionSupportsDisjointRanges() throws {
        let pages = try DocumentTextSession.parsePageSelection("1-2, 4", pageCount: 5)
        XCTAssertEqual(pages, [0, 1, 3])
    }

    func testExtractTextForPageSelectionIncludesHeaderAndPageText() throws {
        let url = try makeTextPDF(pages: ["Doc 1", "Doc 2", "Doc 3"])
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try DocumentTextSession(documentURL: url)
        let text = try session.extractText(pageSelection: "2")

        XCTAssertTrue(text.contains("--- Page 2 ---"))
        XCTAssertTrue(text.contains("Doc 2"))
    }

    func testExtractTextForCurrentPageUsesLiveDocument() throws {
        let url = try makeTextPDF(pages: ["Doc 1", "Doc 2", "Doc 3"])
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try XCTUnwrap(PDFDocument(url: url))
        let session = DocumentTextSession(document: document)
        let text = try session.extractText(currentPageIndex: 1)

        XCTAssertTrue(text.contains("--- Page 2 ---"))
        XCTAssertTrue(text.contains("Doc 2"))
    }

    func testSelectionScopeReturnsSelectionText() throws {
        let session = DocumentTextSession(document: PDFDocument())
        XCTAssertEqual(try session.extractText(scope: .selection("Selected text")), "Selected text")
    }

    func testParsePageSelectionThrowsForInvalidToken() {
        XCTAssertThrowsError(try DocumentTextSession.parsePageSelection("1, abc", pageCount: 3)) { error in
            XCTAssertEqual(error as? PDFTextExtractorError, .invalidPageSelection("abc"))
        }
    }

    func testParsePageSelectionThrowsForOutOfRangePage() {
        XCTAssertThrowsError(try DocumentTextSession.parsePageSelection("4", pageCount: 3)) { error in
            XCTAssertEqual(error as? PDFTextExtractorError, .pageOutOfRange(4, 3))
        }
    }

    private func makeTextPDF(pages: [String]) throws -> URL {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "DocumentTextSessionTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF data consumer"])
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "DocumentTextSessionTests", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF context"])
        }

        for pageText in pages {
            let box = CGRect(x: 0, y: 0, width: 200, height: 200)
            context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)

            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: pageText, attributes: attributes))

            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 24, y: 96)
            CTLineDraw(line, context)
            context.restoreGState()

            context.endPDFPage()
        }

        context.closePDF()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: url, options: [.atomic])
        return url
    }
}
