import AppKit
import CryptoKit
import PDFKit
@testable import PDFQuickFix
import XCTest

final class CleanupEvidenceTests: XCTestCase {
    func testGeneratorCreatesVersionedPrivacySafeEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("private-source.pdf")
        let outputURL = directory.appendingPathComponent("shared-output.pdf")
        try makePDF(
            text: "RAW PRIVATE TEXT",
            metadata: [PDFDocumentAttribute.authorAttribute: "Secret Author"],
            includeStructure: true
        )
        .write(to: sourceURL)
        try makePDF(text: "PUBLIC TEXT", metadata: [:]).write(to: outputURL)

        let verification = CleanupEvidenceGenerator.verifyRedactions(
            candidates: ["RAW PRIVATE TEXT", "API-KEY-SECRET"],
            outputExtractedText: "A repeated API-KEY-SECRET appeared elsewhere"
        )
        let evidence = try CleanupEvidenceGenerator.generate(
            sourceURL: sourceURL,
            outputURL: outputURL,
            quickFixTelemetry: CleanupQuickFixTelemetry(
                redactionRectangleCount: 1,
                suppressedOCRRunCount: 2,
                localOCRPageCount: 1,
                cloudOCRPageCount: 0,
                visionOCRPageCount: 0,
                ocrDisabledPageCount: 0,
                emptyOCRPageCount: 0,
                localOCRFallbackCount: 0
            ),
            comparison: CleanupComparisonSummary(
                comparedPageCount: 1,
                matchingPageCount: 1,
                changedPageCount: 0,
                maximumDifferenceRatio: 0
            ),
            redactionVerification: verification,
            verdict: .reviewRequired,
            warnings: ["Manual visual review remains required."]
        )

        XCTAssertEqual(evidence.schemaVersion, "1.0")
        XCTAssertEqual(evidence.operationKind, .quickFix)
        XCTAssertNil(evidence.sanitizeProfile)
        XCTAssertLessThanOrEqual(evidence.generatedAt, Date())
        XCTAssertEqual(evidence.source.fileName, "private-source.pdf")
        XCTAssertEqual(evidence.output.fileName, "shared-output.pdf")
        XCTAssertEqual(evidence.source.pageCount, 1)
        XCTAssertEqual(evidence.output.pageCount, 1)
        XCTAssertEqual(evidence.source.searchableTextPageCount, 1)
        XCTAssertGreaterThan(evidence.source.searchableTextCharacterCount, 0)
        XCTAssertTrue(evidence.source.metadataFieldLabels.contains("Author"))
        XCTAssertFalse(evidence.output.metadataFieldLabels.contains("Author"))
        XCTAssertEqual(evidence.source.sha256.count, 64)
        XCTAssertEqual(evidence.source.byteCount, try Data(contentsOf: sourceURL).count)
        XCTAssertFalse(evidence.source.isEncrypted)
        XCTAssertGreaterThanOrEqual(evidence.source.annotationCount, 1)
        XCTAssertEqual(evidence.source.outlineCount, 1)
        XCTAssertEqual(evidence.redactionVerification?.status, .reviewRequired)
        XCTAssertEqual(evidence.redactionVerification?.checkedCandidateCount, 2)
        XCTAssertEqual(evidence.redactionVerification?.detectedCandidateCount, 1)

        let json = try CleanupEvidenceWriter.jsonData(for: evidence)
        let serialized = try XCTUnwrap(String(data: json, encoding: .utf8))
        XCTAssertFalse(serialized.contains(directory.path))
        XCTAssertFalse(serialized.contains("Secret Author"))
        XCTAssertFalse(serialized.contains("RAW PRIVATE TEXT"))
        XCTAssertFalse(serialized.contains("API-KEY-SECRET"))
        XCTAssertFalse(serialized.localizedCaseInsensitiveContains("model"))
        XCTAssertFalse(serialized.localizedCaseInsensitiveContains("apiKey"))

        let decoded = try JSONDecoder().decode(CleanupEvidence.self, from: json)
        XCTAssertEqual(decoded, evidence)
    }

    func testRedactionVerificationRequiresReviewForAutomaticMatches() {
        let passed = CleanupEvidenceGenerator.verifyRedactions(
            candidates: ["removed@example.com"],
            outputExtractedText: "No sensitive content remains."
        )
        XCTAssertEqual(passed.status, .passed)
        XCTAssertEqual(passed.checkedCandidateCount, 1)
        XCTAssertEqual(passed.detectedCandidateCount, 0)

        let ambiguous = CleanupEvidenceGenerator.verifyRedactions(
            candidates: ["removed@example.com"],
            outputExtractedText: "Footer contact: REMOVED@example.com"
        )
        XCTAssertEqual(ambiguous.status, .reviewRequired)
        XCTAssertEqual(ambiguous.detectedCandidateCount, 1)

        let confirmed = CleanupEvidenceGenerator.verifyRedactions(
            candidates: ["removed@example.com"],
            outputExtractedText: "Target still contains removed@example.com",
            confirmedLeak: true
        )
        XCTAssertEqual(confirmed.status, .failed)

        let notApplicable = CleanupEvidenceGenerator.verifyRedactions(
            candidates: [],
            outputExtractedText: "Anything"
        )
        XCTAssertEqual(notApplicable.status, .notApplicable)
    }

    func testWriterProducesDeterministicJSONAndTextAndAtomicallyReplacesFiles() throws {
        let evidence = CleanupEvidence(
            source: CleanupDocumentFacts(
                fileName: "in.pdf", sha256: String(repeating: "a", count: 64), byteCount: 10,
                pageCount: 1, searchableTextPageCount: 0, searchableTextCharacterCount: 0,
                isEncrypted: false, metadataFieldLabels: ["Author"], annotationCount: 0, outlineCount: 0
            ),
            output: CleanupDocumentFacts(
                fileName: "out.pdf", sha256: String(repeating: "b", count: 64), byteCount: 8,
                pageCount: 1, searchableTextPageCount: 0, searchableTextCharacterCount: 0,
                isEncrypted: false, metadataFieldLabels: [], annotationCount: 0, outlineCount: 0
            ),
            quickFixTelemetry: nil,
            comparison: nil,
            redactionVerification: nil,
            verdict: .passed,
            warnings: [],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(
            try CleanupEvidenceWriter.jsonData(for: evidence),
            try CleanupEvidenceWriter.jsonData(for: evidence)
        )
        let text = CleanupEvidenceWriter.text(for: evidence)
        XCTAssertTrue(text.hasPrefix("PDFQuickFix Cleanup Evidence\nSchema version: 1.0\n"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanupEvidenceWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsonURL = directory.appendingPathComponent("evidence.json")
        let textURL = directory.appendingPathComponent("evidence.txt")
        try Data("old".utf8).write(to: jsonURL)
        try Data("old".utf8).write(to: textURL)

        try CleanupEvidenceWriter.writeJSON(evidence, to: jsonURL)
        try CleanupEvidenceWriter.writeText(evidence, to: textURL)

        XCTAssertEqual(try Data(contentsOf: jsonURL), try CleanupEvidenceWriter.jsonData(for: evidence))
        XCTAssertEqual(try String(contentsOf: textURL, encoding: .utf8), text)
    }

    private func makePDF(text: String,
                         metadata: [PDFDocumentAttribute: Any],
                         includeStructure: Bool = false) throws -> Data
    {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        textView.string = text
        let document = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        document.documentAttributes = metadata
        if includeStructure, let page = document.page(at: 0) {
            page.addAnnotation(PDFAnnotation(
                bounds: CGRect(x: 20, y: 20, width: 20, height: 20),
                forType: .text,
                withProperties: nil
            ))
            let root = PDFOutline()
            let child = PDFOutline()
            child.label = "Page 1"
            child.destination = PDFDestination(page: page, at: .zero)
            root.insertChild(child, at: 0)
            document.outlineRoot = root
        }
        return try XCTUnwrap(document.dataRepresentation())
    }
}
