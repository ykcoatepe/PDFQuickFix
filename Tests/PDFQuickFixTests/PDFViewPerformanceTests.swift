import XCTest
import PDFKit
@testable import PDFQuickFix

final class PDFViewPerformanceTests: XCTestCase {
    private func makeViewWithDocument(pageCount: Int = 2) throws -> PDFView {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: pageCount)
        guard let doc = PDFDocument(url: url) else {
            XCTFail("Unable to load test PDF")
            throw NSError(domain: "PDFViewPerformanceTests", code: -1)
        }
        let view = PDFView()
        view.document = doc
        return view
    }

    func testPerformanceTuningForSmallDocumentKeepsContinuousMode() throws {
        let view = try makeViewWithDocument()
        view.applyPerformanceTuning(isLargeDocument: false,
                                    desiredDisplayMode: .singlePageContinuous,
                                    resetScale: true)

        XCTAssertEqual(view.displayMode, .singlePageContinuous)
        XCTAssertTrue(view.displaysPageBreaks)
        XCTAssertTrue(view.autoScales)

        let expectedScale = view.scaleFactorForSizeToFit
        XCTAssertEqual(view.scaleFactor, expectedScale, accuracy: 0.0001)
    }

    func testPerformanceTuningForLargeDocumentForcesSinglePage() throws {
        let view = try makeViewWithDocument()
        view.applyPerformanceTuning(isLargeDocument: true,
                                    desiredDisplayMode: .singlePageContinuous,
                                    resetScale: true)

        XCTAssertEqual(view.displayMode, .singlePage)
        XCTAssertFalse(view.displaysPageBreaks)
        XCTAssertFalse(view.autoScales)

        let expectedScale = view.scaleFactorForSizeToFit
        XCTAssertEqual(view.scaleFactor, expectedScale, accuracy: 0.0001)
        XCTAssertEqual(view.minScaleFactor, expectedScale, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(view.maxScaleFactor, expectedScale * 4)
    }

    func testPerformanceTuningRespectsResetScaleFlag() throws {
        let view = try makeViewWithDocument()
        view.applyPerformanceTuning(isLargeDocument: true,
                                    desiredDisplayMode: .singlePageContinuous,
                                    resetScale: true)

        let baselineScale = view.scaleFactor
        view.scaleFactor = baselineScale * 1.5

        view.applyPerformanceTuning(isLargeDocument: true,
                                    desiredDisplayMode: .singlePageContinuous,
                                    resetScale: false)

        XCTAssertEqual(view.scaleFactor, baselineScale * 1.5, accuracy: 0.0001)
    }
}
