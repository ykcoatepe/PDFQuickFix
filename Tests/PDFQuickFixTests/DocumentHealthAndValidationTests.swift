import XCTest
import Combine
@testable import PDFQuickFix

@MainActor
final class DocumentHealthAndValidationTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testRedactionPatternThrowsForInvalidRegex() {
        XCTAssertThrowsError(try RedactionPattern(name: "Bad", pattern: "("))
    }

    func testDocumentHealthSummaryIncludesQuickFixWarnings() {
        let summary = DocumentHealthSummary.build(
            documentName: "Test.pdf",
            pageCount: 4,
            isRepaired: true,
            isLargeDocument: false,
            isMassiveDocument: false,
            skippedQuickValidation: true,
            validationStatus: "Validated 4/4",
            quickFixResult: QuickFixResult(
                outputURL: URL(fileURLWithPath: "/tmp/test-fixed.pdf"),
                isTemporaryOutput: false,
                previewPageIndex: 0,
                redactionReport: RedactionReport(
                    pagesWithRedactions: [0],
                    totalRedactionRectCount: 2,
                    suppressedOCRRunCount: 1
                ),
                ocrReport: OCRReport(
                    totalPages: 4,
                    localOCRPages: 1,
                    cloudOCRPages: 0,
                    visionOCRPages: 3,
                    ocrDisabledPages: 0,
                    emptyOCRPages: 1,
                    emptyOCRPageIndices: [2],
                    localOCRFallbackCount: 1
                )
            )
        )

        XCTAssertTrue(summary.issues.contains(where: { $0.title == "Document was normalized on open" }))
        XCTAssertTrue(summary.issues.contains(where: { $0.title == "Quick validation was skipped" }))
        XCTAssertTrue(summary.issues.contains(where: { $0.title == "Empty OCR pages detected" }))
        XCTAssertTrue(summary.issues.contains(where: { $0.title == "OCR fallback occurred" }))
    }

    func testReaderControllerMassiveOpenRetainsProvidedSecurityScope() throws {
        let controller = ReaderControllerPro()
        let pdfURL = try TestPDFBuilder.makeMultipagePDF(pageCount: 2001, textPrefix: "Massive", size: CGSize(width: 10, height: 10))
        let access = SecurityScopedAccess(url: pdfURL)
        let expectation = expectation(description: "Massive reader open completes")

        controller.$document
            .compactMap { $0 }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: pdfURL, access: access)
        }

        wait(for: [expectation], timeout: 20)
        XCTAssertTrue(controller.hasActiveSecurityScope)
        XCTAssertTrue(controller.skippedQuickValidation)
    }
}
