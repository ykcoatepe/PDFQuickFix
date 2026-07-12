import AppKit
import CoreGraphics
import PDFKit
@testable import PDFQuickFix
import XCTest

final class CleanupComparisonTests: XCTestCase {
    func testMetadataOnlyCleanupLeavesPageUnchangedAndReportsLabelsWithoutValues() throws {
        let source = try makeDocument(pages: [.blank])
        source.documentAttributes = [
            PDFDocumentAttribute.authorAttribute: "Private Person",
            PDFDocumentAttribute.titleAttribute: "Confidential Project",
        ]
        let output = try makeDocument(pages: [.blank])
        output.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Replacement title",
        ]

        let result = try CleanupComparisonEngine().compare(source: source, output: output)

        XCTAssertEqual(result.sourcePageCount, 1)
        XCTAssertEqual(result.outputPageCount, 1)
        XCTAssertEqual(result.pages.map(\.classification), [.unchanged])
        XCTAssertEqual(result.changedPages, [])
        XCTAssertEqual(result.metadataFieldsRemoved, ["Author"])
        XCTAssertEqual(result.metadataFieldsRemaining, ["Title"])
        XCTAssertFalse(String(reflecting: result).contains("Private Person"))
        XCTAssertFalse(String(reflecting: result).contains("Confidential Project"))
        XCTAssertFalse(String(reflecting: result).contains("Replacement title"))
    }

    func testInvisibleExtractableTextChangeIsClassifiedAsTextLayerChanged() throws {
        let source = try makeDocument(pages: [.invisibleText("Customer account 123")])
        let output = try makeDocument(pages: [.invisibleText("Customer account removed")])

        let result = try CleanupComparisonEngine().compare(source: source, output: output)
        let page = try XCTUnwrap(result.pages.first)

        XCTAssertEqual(page.classification, .textLayerChanged)
        XCTAssertNotEqual(page.sourceTextFingerprint, page.outputTextFingerprint)
        XCTAssertNotEqual(page.textCharacterCountDelta, 0)
        XCTAssertLessThanOrEqual(page.visualDifferenceRatio, 0.001)
        XCTAssertEqual(result.changedPages, [1])
        XCTAssertFalse(String(reflecting: result).contains("Customer account"))
    }

    func testVisibleDifferenceTakesVisualChangedPrecedence() throws {
        let source = try makeDocument(pages: [.filled(.black)])
        let output = try makeDocument(pages: [.filled(.white)])

        let result = try CleanupComparisonEngine().compare(source: source, output: output)
        let page = try XCTUnwrap(result.pages.first)

        XCTAssertEqual(page.classification, .visualChanged)
        XCTAssertGreaterThan(page.visualDifferenceRatio, 0.7)
        XCTAssertEqual(result.changedPages, [1])
    }

    func testWhitespaceNormalizationProducesStableFingerprint() throws {
        let source = try makeDocument(pages: [.invisibleText("  Alpha\n\tBeta  ")])
        let output = try makeDocument(pages: [.invisibleText("Alpha Beta")])

        let result = try CleanupComparisonEngine().compare(source: source, output: output)
        let page = try XCTUnwrap(result.pages.first)

        XCTAssertEqual(page.sourceTextFingerprint, page.outputTextFingerprint)
        XCTAssertEqual(page.textCharacterCountDelta, 0)
        XCTAssertEqual(page.classification, .unchanged)
    }

    func testPageCountDifferenceIsBoundedToPageSummariesAndReportsProgress() throws {
        let source = try makeDocument(pages: [.blank, .blank])
        let output = try makeDocument(pages: [.blank])
        var progress: [Double] = []

        let result = try CleanupComparisonEngine().compare(
            source: source,
            output: output,
            progress: { progress.append($0) }
        )

        XCTAssertEqual(result.sourcePageCount, 2)
        XCTAssertEqual(result.outputPageCount, 1)
        XCTAssertEqual(result.pages.count, 2)
        XCTAssertEqual(result.pages[1].classification, .visualChanged)
        XCTAssertEqual(result.pages[1].visualDifferenceRatio, 1)
        XCTAssertEqual(result.changedPages, [2])
        XCTAssertEqual(progress, [0.5, 1.0])
    }

    func testCancellationStopsBeforeComparingAnotherPage() throws {
        let source = try makeDocument(pages: [.blank, .blank])
        let output = try makeDocument(pages: [.blank, .blank])
        var cancellationChecks = 0

        XCTAssertThrowsError(try CleanupComparisonEngine().compare(
            source: source,
            output: output,
            isCancelled: {
                cancellationChecks += 1
                return cancellationChecks > 1
            }
        )) { error in
            XCTAssertEqual(error as? CleanupComparisonError, .cancelled)
        }
    }
}

private extension CleanupComparisonTests {
    enum PageFixture {
        case blank
        case filled(NSColor)
        case invisibleText(String)
    }

    func makeDocument(pages: [PageFixture]) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        var mediaBox = CGRect(x: 0, y: 0, width: 160, height: 120)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FixtureError.couldNotCreateContext
        }

        for fixture in pages {
            context.beginPDFPage(nil)
            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            NSColor.white.setFill()
            mediaBox.fill()

            switch fixture {
            case .blank:
                break
            case let .filled(color):
                color.setFill()
                mediaBox.fill()
            case let .invisibleText(text):
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 16),
                        .foregroundColor: NSColor.clear,
                    ]
                ).draw(in: CGRect(x: 10, y: 50, width: 140, height: 40))
            }

            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(url: url) else {
            throw FixtureError.couldNotLoadDocument
        }
        return document
    }

    enum FixtureError: Error {
        case couldNotCreateContext
        case couldNotLoadDocument
    }
}
