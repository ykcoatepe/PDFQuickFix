import PDFKit
@testable import PDFQuickFix
import XCTest

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

    func testSavedCopyPreservesCleanupEvidenceAndComparison() throws {
        let sourceURL = try TestPDFBuilder.makeSimplePDF(text: "Source", size: CGSize(width: 200, height: 200))
        let tempURL = try TestPDFBuilder.makeSimplePDF(text: "Output", size: CGSize(width: 200, height: 200))
        let savedURL = URL(fileURLWithPath: "/tmp/quickfix-evidence-saved.pdf")
        let comparison = try CleanupComparisonEngine().compare(
            source: XCTUnwrap(PDFDocument(url: sourceURL)),
            output: XCTUnwrap(PDFDocument(url: tempURL))
        )
        let evidence = try CleanupEvidenceGenerator.generate(
            sourceURL: sourceURL,
            outputURL: tempURL,
            comparison: comparison.evidenceSummary,
            verdict: .reviewRequired
        )
        let result = QuickFixResult(
            outputURL: tempURL,
            isTemporaryOutput: true,
            previewPageIndex: 0,
            redactionReport: RedactionReport(
                pagesWithRedactions: [],
                totalRedactionRectCount: 0,
                suppressedOCRRunCount: 0
            ),
            ocrReport: OCRReport(
                totalPages: 1,
                localOCRPages: 0,
                cloudOCRPages: 0,
                visionOCRPages: 0,
                ocrDisabledPages: 1,
                emptyOCRPages: 0,
                emptyOCRPageIndices: [],
                localOCRFallbackCount: 0
            ),
            sourceURL: sourceURL,
            cleanupEvidence: evidence,
            cleanupComparison: comparison
        )

        let saved = result.savedCopy(outputURL: savedURL)

        XCTAssertEqual(saved.sourceURL, sourceURL)
        XCTAssertEqual(saved.cleanupEvidence?.source, evidence.source)
        XCTAssertEqual(saved.cleanupEvidence?.output.fileName, savedURL.lastPathComponent)
        XCTAssertEqual(saved.cleanupEvidence?.output.sha256, evidence.output.sha256)
        XCTAssertEqual(saved.cleanupComparison, comparison)
    }

    func testConvertedImageSnapshotIsRetainedAcrossSave() {
        let snapshotURL = URL(fileURLWithPath: "/tmp/photo-converted.pdf")
        let result = QuickFixResult(
            outputURL: URL(fileURLWithPath: "/tmp/output.pdf"),
            isTemporaryOutput: true,
            previewPageIndex: nil,
            redactionReport: RedactionReport(pagesWithRedactions: [], totalRedactionRectCount: 0, suppressedOCRRunCount: 0),
            ocrReport: OCRReport(totalPages: 1, localOCRPages: 0, cloudOCRPages: 0, visionOCRPages: 0, ocrDisabledPages: 0, emptyOCRPages: 0, emptyOCRPageIndices: [], localOCRFallbackCount: 0)
        )
        .retainingSourceSnapshot(at: snapshotURL, displayFileName: "photo-converted.pdf")

        let saved = result.savedCopy(outputURL: URL(fileURLWithPath: "/tmp/saved.pdf"))

        XCTAssertEqual(saved.sourceURL, snapshotURL)
        XCTAssertTrue(saved.isTemporarySource)
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

    func testResultStoreFallsBackToSecondaryURL() {
        let store = QuickFixResultStore()
        let sourceURL = URL(fileURLWithPath: "/tmp/source.pdf")
        let repairedURL = URL(fileURLWithPath: "/tmp/source-repaired.pdf")
        let result = QuickFixResult(
            outputURL: URL(fileURLWithPath: "/tmp/fixed.pdf"),
            isTemporaryOutput: false,
            previewPageIndex: 1,
            redactionReport: RedactionReport(
                pagesWithRedactions: [1],
                totalRedactionRectCount: 1,
                suppressedOCRRunCount: 0
            ),
            ocrReport: OCRReport(
                totalPages: 2,
                localOCRPages: 1,
                cloudOCRPages: 0,
                visionOCRPages: 1,
                ocrDisabledPages: 0,
                emptyOCRPages: 0,
                emptyOCRPageIndices: [],
                localOCRFallbackCount: 0
            )
        )

        store.set(result, sourceURL: sourceURL)

        XCTAssertEqual(store.result(primaryURL: repairedURL, fallbackURL: sourceURL)?.outputURL, result.outputURL)
    }
}
