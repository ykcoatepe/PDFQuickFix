import PDFKit
@testable import PDFQuickFix
import XCTest

final class PDFQuickFixEngineTests: XCTestCase {
    func testMatchedRedactionCandidatesReturnsOnlyMatchedText() throws {
        let regexes = try [
            NSRegularExpression(pattern: #"\b\d{3}-\d{2}-\d{4}\b"#),
            NSRegularExpression(pattern: #"secret@example\.com"#, options: .caseInsensitive),
        ]

        let candidates = PDFQuickFixEngine.matchedRedactionCandidates(
            in: "Public text, 123-45-6789 and SECRET@example.com",
            regexes: regexes
        )

        XCTAssertEqual(candidates, ["123-45-6789", "SECRET@example.com"])
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
              let outPage = outDoc.page(at: 0)
        else {
            XCTFail("Unable to load processed PDF")
            return
        }

        let bounds = outPage.bounds(for: .mediaBox)
        XCTAssertGreaterThan(bounds.width, 0, "Output page MediaBox width should be non-zero")
        XCTAssertGreaterThan(bounds.height, 0, "Output page MediaBox height should be non-zero")
        XCTAssertNotNil(outPage.pageRef, "Output page should have a CGPDFPage backing reference")
    }

    func testExplicitTemporaryOutputRemainsMarkedTemporary() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "Hello", size: CGSize(width: 200, height: 200))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let engine = PDFQuickFixEngine(options: QuickFixOptions(doOCR: false, dpi: 72, redactionPadding: 0), languages: ["en-US"])
        let result = try engine.processResult(
            inputURL: inputURL,
            outputURL: outputURL,
            isTemporaryOutput: true,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        XCTAssertTrue(result.isTemporaryOutput)
        XCTAssertEqual(result.outputURL, outputURL)
    }

    func testProcessResultIncludesCleanupEvidenceAndComparison() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "Evidence source", size: CGSize(width: 200, height: 200))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let engine = PDFQuickFixEngine(
            options: QuickFixOptions(doOCR: false, dpi: 72, redactionPadding: 0),
            languages: ["en-US"]
        )
        let result = try engine.processResult(
            inputURL: inputURL,
            outputURL: outputURL,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        XCTAssertEqual(result.sourceURL, inputURL)
        XCTAssertEqual(result.cleanupEvidence?.source.sha256.count, 64)
        XCTAssertEqual(result.cleanupEvidence?.output.sha256.count, 64)
        XCTAssertEqual(result.cleanupEvidence?.verdict, .passed)
        XCTAssertEqual(result.cleanupComparison?.sourcePageCount, 1)
        XCTAssertEqual(result.cleanupComparison?.outputPageCount, 1)
    }

    func testEvidenceUsesResolvedRepairSourceWhenOriginalIsUnreadable() throws {
        let originalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        let repairedURL = try TestPDFBuilder.makeSimplePDF(text: "Recovered source", size: CGSize(width: 200, height: 200))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try Data("not-readable-by-pdfkit".utf8).write(to: originalURL)
        defer {
            try? FileManager.default.removeItem(at: originalURL)
            try? FileManager.default.removeItem(at: repairedURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let engine = PDFQuickFixEngine(
            options: QuickFixOptions(doOCR: false, dpi: 72, redactionPadding: 0),
            languages: ["en-US"],
            repairSourceURL: { _ in repairedURL }
        )

        let result = try engine.processResult(
            inputURL: originalURL,
            outputURL: outputURL,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        XCTAssertEqual(result.sourceURL, repairedURL)
        XCTAssertTrue(result.isTemporarySource)
        XCTAssertEqual(result.cleanupEvidence?.source.sha256.count, 64)
        XCTAssertEqual(result.cleanupEvidence?.source.fileName, originalURL.deletingPathExtension().lastPathComponent + "-repaired.pdf")
    }
}
