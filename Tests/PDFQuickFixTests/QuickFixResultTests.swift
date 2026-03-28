import XCTest
@testable import PDFQuickFix

@MainActor
final class QuickFixResultTests: XCTestCase {
    func testSavedCopyPreservesPreviewMetadata() {
        let tempURL = URL(fileURLWithPath: "/tmp/quickfix-temp.pdf")
        let savedURL = URL(fileURLWithPath: "/tmp/quickfix-saved.pdf")
        let result = QuickFixResult(
            outputURL: tempURL,
            isTemporaryOutput: true,
            previewPageIndex: 4,
            redactionReport: RedactionReport(
                pagesWithRedactions: [1, 4],
                totalRedactionRectCount: 3,
                suppressedOCRRunCount: 2
            ),
            ocrReport: OCRReport(
                totalPages: 6,
                localOCRPages: 2,
                cloudOCRPages: 1,
                visionOCRPages: 3,
                ocrDisabledPages: 0,
                emptyOCRPages: 1,
                emptyOCRPageIndices: [4],
                localOCRFallbackCount: 0
            )
        )

        let saved = result.savedCopy(outputURL: savedURL)

        XCTAssertEqual(saved.outputURL, savedURL)
        XCTAssertFalse(saved.isTemporaryOutput)
        XCTAssertEqual(saved.previewPageIndex, 4)
        XCTAssertEqual(saved.redactionReport.pagesWithRedactions, [1, 4])
        XCTAssertEqual(saved.ocrReport.emptyOCRPageIndices, [4])
    }

    func testResultStoreAliasesPreviousOutputURL() {
        let store = QuickFixResultStore()
        let sourceURL = URL(fileURLWithPath: "/tmp/source.pdf")
        let tempURL = URL(fileURLWithPath: "/tmp/quickfix-temp.pdf")
        let savedURL = URL(fileURLWithPath: "/tmp/quickfix-saved.pdf")
        let result = QuickFixResult(
            outputURL: savedURL,
            isTemporaryOutput: false,
            previewPageIndex: 2,
            redactionReport: RedactionReport(
                pagesWithRedactions: [2],
                totalRedactionRectCount: 1,
                suppressedOCRRunCount: 1
            ),
            ocrReport: OCRReport(
                totalPages: 3,
                localOCRPages: 1,
                cloudOCRPages: 0,
                visionOCRPages: 2,
                ocrDisabledPages: 0,
                emptyOCRPages: 0,
                emptyOCRPageIndices: [],
                localOCRFallbackCount: 0
            )
        )

        store.set(result, previousOutputURL: tempURL, sourceURL: sourceURL)

        XCTAssertEqual(store.result(for: savedURL)?.outputURL, savedURL)
        XCTAssertEqual(store.result(for: tempURL)?.outputURL, savedURL)
        XCTAssertEqual(store.result(for: sourceURL)?.outputURL, savedURL)
    }
}
