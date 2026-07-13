import CoreGraphics
import PDFKit
@testable import PDFQuickFix
import PDFQuickFixKit
import XCTest

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
            "CreationDate": "2024-06-01T12:34:56Z",
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

    func testPrivacyCleanProfile() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Secret Content")
        guard let document = PDFDocument(url: url) else {
            XCTFail("Unable to load test PDF")
            return
        }
        document.documentAttributes = ["Title": "Secret Title"]

        let options = PDFDocumentSanitizer.Options.from(profile: .privacyClean)

        let sanitized = try PDFDocumentSanitizer.sanitize(document: document, sourceURL: url, options: options)

        // Check Metadata
        XCTAssertNil(sanitized.documentAttributes?["Title"])
        XCTAssertTrue(sanitized.documentAttributes?.isEmpty ?? true)

        // Check Content (should be rasterized, so text is gone)
        XCTAssertEqual(sanitized.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "")
    }

    func testRasterizeModeThrowsWhenPageRasterizationFails() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Must not survive rasterization failure")
        let validDocument = try XCTUnwrap(PDFDocument(url: url))
        let validData = try XCTUnwrap(validDocument.dataRepresentation())
        let document = RasterizationFailurePDFDocument(fallbackData: validData)

        XCTAssertThrowsError(
            try PDFDocumentSanitizer.sanitize(
                document: document,
                sourceURL: nil,
                options: .init(rebuildMode: .rasterize, validationPageLimit: 1)
            )
        ) { error in
            guard case PDFDocumentSanitizerError.pageRenderFailed = error else {
                XCTFail("Expected pageRenderFailed, got \(error)")
                return
            }
        }
    }

    func testRasterizeModePreservesEdgeTriggeredCancellation() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Cancel rasterization")
        let document = try XCTUnwrap(PDFDocument(url: url))
        var cancellationChecks = 0

        XCTAssertThrowsError(
            try PDFDocumentSanitizer.sanitize(
                document: document,
                sourceURL: url,
                options: .init(
                    rebuildMode: .rasterize,
                    validationPageLimit: 1,
                    sanitizeAnnotations: false
                ),
                shouldCancel: {
                    cancellationChecks += 1
                    return cancellationChecks == 1
                }
            )
        ) { error in
            guard case PDFDocumentSanitizerError.cancelled = error else {
                XCTFail("Expected cancelled, got \(error)")
                return
            }
        }
    }

    func testKeepEditableProfileRemovesOutline() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Editable Content")
        guard let document = PDFDocument(url: url) else {
            XCTFail("Unable to load test PDF")
            return
        }

        // Add fake outline
        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "To Be Removed"
        root.insertChild(child, at: 0)
        document.outlineRoot = root

        XCTAssert(document.outlineRoot?.numberOfChildren ?? 0 > 0)

        let options = PDFDocumentSanitizer.Options.from(profile: .keepEditable)
        let sanitized = try PDFDocumentSanitizer.sanitize(document: document, sourceURL: url, options: options)

        // Assert outline children are gone
        XCTAssertEqual(sanitized.outlineRoot?.numberOfChildren ?? 0, 0)
    }

    func testSanitizeValidatesUnlockedSnapshotBeforeLockedSourceURL() throws {
        let plainURL = try TestPDFBuilder.makeSimplePDF(text: "Encrypted sanitize content")
        let plainDocument = try XCTUnwrap(PDFDocument(url: plainURL))
        let encryptedData = try XCTUnwrap(PDFSecurity.encrypt(document: plainDocument, userPassword: "user-pass"))
        let encryptedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try encryptedData.write(to: encryptedURL)
        defer { try? FileManager.default.removeItem(at: encryptedURL) }

        let encryptedDocument = try XCTUnwrap(PDFDocument(url: encryptedURL))
        XCTAssertTrue(encryptedDocument.isLocked)
        XCTAssertTrue(encryptedDocument.unlock(withPassword: "user-pass"))

        let unlockedSnapshot = try PDFOps.privacyPreservingSnapshot(document: encryptedDocument)
        let sanitized = try PDFDocumentSanitizer.sanitize(
            document: unlockedSnapshot,
            sourceURL: encryptedURL,
            options: .init(rebuildMode: .never, validationPageLimit: 1)
        )

        XCTAssertEqual(sanitized.pageCount, 1)
    }

    func testSanitizeUsesURLBackedValidationForSourceDocument() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "URL-backed validation")
        let document = try XCTUnwrap(TrackingPDFDocument(url: url))

        let sanitized = try PDFDocumentSanitizer.sanitize(
            document: document,
            sourceURL: url,
            options: .init(rebuildMode: .never,
                           validationPageLimit: 1,
                           sanitizeAnnotations: false,
                           sanitizeOutline: false)
        )

        XCTAssertEqual(sanitized.pageCount, 1)
        XCTAssertEqual(document.dataRepresentationCallCount, 0)
    }

    // MARK: - Trust Checks

    /// Trust check: Verify lightClean removes XMP metadata, not just document attributes.
    /// XMP is embedded as raw XML in the PDF stream. dataRepresentation() may not strip it.
    func testLightCleanRemovesXMP() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "XMP Test Content")
        guard let document = PDFDocument(url: url) else {
            XCTFail("Unable to load test PDF")
            return
        }

        // Set some document attributes that PDFKit might embed as XMP
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "XMP Title",
            PDFDocumentAttribute.authorAttribute: "XMP Author",
            PDFDocumentAttribute.subjectAttribute: "XMP Subject",
        ]

        let options = PDFDocumentSanitizer.Options.from(profile: .lightClean)
        let sanitized = try PDFDocumentSanitizer.sanitize(document: document, sourceURL: url, options: options)

        // Get the raw data representation
        guard let outputData = sanitized.dataRepresentation() else {
            XCTFail("Could not get data representation")
            return
        }

        // Check for XMP markers in raw bytes
        // XMP typically starts with "<?xpacket" or contains "<x:xmpmeta"
        let dataString = String(data: outputData, encoding: .isoLatin1) ?? ""
        let hasXPacket = dataString.contains("<?xpacket")
        let hasXMPMeta = dataString.contains("<x:xmpmeta")

        XCTAssertFalse(hasXPacket, "XMP packet marker should be removed by lightClean profile")
        XCTAssertFalse(hasXMPMeta, "XMP metadata block should be removed by lightClean profile")

        // At minimum, document attributes should be empty
        XCTAssertTrue(sanitized.documentAttributes?.isEmpty ?? true, "Document attributes should be cleared")

        // Check that our specific metadata values are not in the output
        XCTAssertFalse(dataString.contains("XMP Title"), "Title should not appear in output")
        XCTAssertFalse(dataString.contains("XMP Author"), "Author should not appear in output")
    }

    /// Trust check: Verify keepEditable outline removal persists after save/reload cycle.
    /// Some PDFs may "rehydrate" outline on save if changes aren't properly serialized.
    func testKeepEditableOutlinePersistsAfterSave() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Outline Persistence Test")
        guard let document = PDFDocument(url: url) else {
            XCTFail("Unable to load test PDF")
            return
        }

        // Add outline
        let root = PDFOutline()
        let child1 = PDFOutline()
        child1.label = "Chapter 1"
        let child2 = PDFOutline()
        child2.label = "Chapter 2"
        root.insertChild(child1, at: 0)
        root.insertChild(child2, at: 1)
        document.outlineRoot = root

        XCTAssertEqual(document.outlineRoot?.numberOfChildren ?? 0, 2, "Setup: should have 2 outline children")

        let options = PDFDocumentSanitizer.Options.from(profile: .keepEditable)
        let sanitized = try PDFDocumentSanitizer.sanitize(document: document, sourceURL: url, options: options)

        // Verify immediate removal
        XCTAssertEqual(sanitized.outlineRoot?.numberOfChildren ?? 0, 0, "Outline should be cleared")

        // Simulate save/reload cycle
        guard let savedData = sanitized.dataRepresentation() else {
            XCTFail("Could not get data representation after sanitization")
            return
        }

        guard let reloaded = PDFDocument(data: savedData) else {
            XCTFail("Could not reload PDF from data")
            return
        }

        // Verify outline removal persists after reload
        let reloadedOutlineCount = reloaded.outlineRoot?.numberOfChildren ?? 0
        XCTAssertEqual(reloadedOutlineCount, 0, "Outline removal should persist after save/reload cycle")
    }
}

private final class TrackingPDFDocument: PDFDocument {
    private(set) var dataRepresentationCallCount = 0

    override func dataRepresentation() -> Data? {
        dataRepresentationCallCount += 1
        return super.dataRepresentation()
    }
}

private final class RasterizationFailurePDFDocument: PDFDocument {
    private let fallbackData: Data

    init(fallbackData: Data) {
        self.fallbackData = fallbackData
        super.init()
    }

    override var pageCount: Int {
        1
    }

    override func page(at index: Int) -> PDFPage? {
        nil
    }

    override func dataRepresentation() -> Data? {
        fallbackData
    }
}
