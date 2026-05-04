import Combine
import PDFKit
@testable import PDFQuickFix
import XCTest

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
        XCTAssertEqual(summary.shareReadiness, .blocked)
    }

    func testDocumentHealthSummaryMarksCleanDocumentReadyForReview() {
        let summary = DocumentHealthSummary.build(
            documentName: "Clean.pdf",
            pageCount: 2,
            isRepaired: false,
            isLargeDocument: false,
            isMassiveDocument: false,
            skippedQuickValidation: false,
            validationStatus: nil,
            quickFixResult: nil
        )

        XCTAssertEqual(summary.shareReadiness, .ready)
        XCTAssertTrue(summary.issues.contains(where: { $0.title == "No active document warnings" }))
    }

    func testDocumentHealthSummaryMarksSkippedValidationForReview() {
        let summary = DocumentHealthSummary.build(
            documentName: "NeedsReview.pdf",
            pageCount: 1200,
            isRepaired: false,
            isLargeDocument: false,
            isMassiveDocument: false,
            skippedQuickValidation: true,
            validationStatus: nil,
            quickFixResult: nil
        )

        XCTAssertEqual(summary.shareReadiness, .reviewRecommended)
    }

    func testDocumentHealthSummaryFlagsOutboundMetadata() {
        let summary = DocumentHealthSummary.build(
            documentName: "Metadata.pdf",
            pageCount: 1,
            isRepaired: false,
            isLargeDocument: false,
            isMassiveDocument: false,
            skippedQuickValidation: false,
            validationStatus: nil,
            quickFixResult: nil,
            documentAttributes: [
                PDFDocumentAttribute.authorAttribute: "Internal Ops",
                PDFDocumentAttribute.creatorAttribute: "Scanner",
                "Subject": "   ",
            ]
        )

        XCTAssertEqual(summary.shareReadiness, .reviewRecommended)
        XCTAssertTrue(summary.issues.contains(where: {
            $0.title == "Outbound metadata present" &&
                $0.detail.contains("author") &&
                $0.detail.contains("creator") &&
                !$0.detail.contains("subject")
        }))
    }

    func testDocumentHealthBlocksShareReadinessForReplacementTextOverlays() {
        let summary = DocumentHealthSummary.build(
            documentName: "Overlay.pdf",
            pageCount: 1,
            isRepaired: false,
            isLargeDocument: false,
            isMassiveDocument: false,
            skippedQuickValidation: false,
            validationStatus: nil,
            quickFixResult: nil,
            hasReplacementTextAnnotations: true
        )

        XCTAssertEqual(summary.shareReadiness, .blocked)
        XCTAssertTrue(summary.issues.contains(where: {
            $0.severity == .critical &&
                $0.title == "Flatten or sanitize text overlays" &&
                $0.detail.contains("original text layer may remain extractable")
        }))
        XCTAssertFalse(summary.issues.contains(where: { $0.title == "No active document warnings" }))
    }

    func testDocumentHealthPlainTextReportIncludesReadinessAndFindings() {
        let summary = DocumentHealthSummary.build(
            documentName: "Packet.pdf",
            pageCount: 3,
            isRepaired: false,
            isLargeDocument: false,
            isMassiveDocument: false,
            skippedQuickValidation: true,
            validationStatus: nil,
            quickFixResult: nil
        )

        let report = summary.plainTextReport(generatedAt: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(report.contains("PDFQuickFix Document Health Report"))
        XCTAssertTrue(report.contains("Generated: 1970-01-01T00:00:00Z"))
        XCTAssertTrue(report.contains("Document: Packet.pdf"))
        XCTAssertTrue(report.contains("Share readiness: Review recommended before sharing"))
        XCTAssertTrue(report.contains("[WARNING] Quick validation was skipped"))
    }

    func testReaderControllerMassiveOpenRetainsProvidedSecurityScope() throws {
        let controller = ReaderControllerPro()
        let pdfURL = try TestPDFBuilder.makeMultipagePDF(pageCount: 2001, textPrefix: "Massive", size: CGSize(width: 10, height: 10))
        let access = SecurityScopedAccess(url: pdfURL)
        let expectation = expectation(description: "Massive reader open completes")

        controller.$document
            .compactMap(\.self)
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
