import XCTest
import PDFKit
import CoreGraphics
@testable import PDFQuickFix

final class PDFDocumentSanitizerTests: XCTestCase {
    func testSanitizeCoercesAttributeTypes() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Metadata Test")
        guard let document = PDFDocument(url: url) else {
            XCTFail("Unable to load test PDF")
            return
        }
        document.documentAttributes = [
            "Title": NSNumber(value: 42),
            "Keywords": ["alpha", 123, NSDate(timeIntervalSince1970: 0)],
            "CreationDate": "2024-06-01T12:34:56Z"
        ]

        let sanitized = try PDFDocumentSanitizer.sanitize(
            document: document,
            sourceURL: url,
            options: .init(rebuildMode: .never, validationPageLimit: 1)
        )

        let attributes = sanitized.documentAttributes as? [String: Any] ?? [:]
        XCTAssertEqual(attributes["Title"] as? String, "42")
        let keywords = attributes["Keywords"] as? [String]
        XCTAssertEqual(keywords, ["alpha", "123", "1970-01-01T00:00:00Z"])
        XCTAssertNotNil(attributes["CreationDate"] as? Date)
    }

    func testValidateHonorsCancellation() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Cancel Test")
        guard
            let provider = CGDataProvider(url: url as CFURL),
            let cgDocument = CGPDFDocument(provider)
        else {
            XCTFail("Unable to create CGPDFDocument")
            return
        }
        var attempts = 0
        XCTAssertThrowsError(
            try PDFDocumentSanitizer.validate(
                cgDocument: cgDocument,
                options: PDFDocumentSanitizer.ValidationOptions(pageLimit: 5),
                progress: nil,
                shouldCancel: {
                    attempts += 1
                    return attempts >= 1
                }
            )
        ) { error in
            guard case PDFDocumentSanitizerError.cancelled = error else {
                XCTFail("Expected cancellation error, got \(error)")
                return
            }
        }
        XCTAssertGreaterThanOrEqual(attempts, 1)
    }
}
