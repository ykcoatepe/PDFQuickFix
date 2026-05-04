import AppKit
import PDFKit
@testable import PDFQuickFix
import XCTest

final class PDFOpsTests: XCTestCase {
    func testApplyWatermark() throws {
        // Given
        let url = try TestPDFBuilder.makeSimplePDF(text: "Original")
        let document = try XCTUnwrap(PDFDocument(url: url))

        // When
        PDFOps.applyWatermark(document: document,
                              text: "CONFIDENTIAL",
                              fontSize: 24,
                              color: .red,
                              opacity: 0.5,
                              rotation: 45,
                              position: .center,
                              margin: 10)

        // Then
        let page = try XCTUnwrap(document.page(at: 0))
        let annotations = page.annotations
        let watermark = annotations.first { $0.contents == "CONFIDENTIAL" }

        XCTAssertNotNil(watermark)
        XCTAssertEqual(watermark?.type, "FreeText")
        // Note: Exact color/font checks might be tricky due to PDFKit internals,
        // but we verified the content and existence.
    }

    func testApplyHeaderFooter() throws {
        // Given
        let url = try TestPDFBuilder.makeSimplePDF()
        let document = try XCTUnwrap(PDFDocument(url: url))

        // When
        PDFOps.applyHeaderFooter(document: document,
                                 header: "Top Secret",
                                 footer: "Page 1",
                                 margin: 20,
                                 fontSize: 12)

        // Then
        let page = try XCTUnwrap(document.page(at: 0))
        let annotations = page.annotations

        let header = annotations.first { $0.contents == "Top Secret" }
        let footer = annotations.first { $0.contents == "Page 1" }

        XCTAssertNotNil(header)
        XCTAssertNotNil(footer)
    }

    func testCrop() throws {
        // Given
        let url = try TestPDFBuilder.makeSimplePDF(size: CGSize(width: 200, height: 200))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let originalBox = try XCTUnwrap(document.page(at: 0)?.bounds(for: .mediaBox))

        // When
        PDFOps.crop(document: document, inset: 10, target: .allPages)

        // Then
        let page = try XCTUnwrap(document.page(at: 0))
        let newBox = page.bounds(for: .mediaBox)

        XCTAssertEqual(newBox.width, originalBox.width - 20)
        XCTAssertEqual(newBox.height, originalBox.height - 20)
        XCTAssertEqual(newBox.origin.x, originalBox.origin.x + 10)
        XCTAssertEqual(newBox.origin.y, originalBox.origin.y + 10)
    }

    func testOptimizeProducesLoadablePDFData() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Compact me")
        let document = try XCTUnwrap(PDFDocument(url: url))

        let data = try XCTUnwrap(PDFOps.optimize(document: document))
        let optimizedDocument = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(optimizedDocument.pageCount, 1)
        XCTAssertNotNil(optimizedDocument.page(at: 0))
    }

    func testOptimizeFlattensReplacementTextBeforeExport() throws {
        let document = try makeTextBackedDocument(text: "Hidden optimized text")
        addReplacementTextAnnotations(to: document, replacement: "Public optimized text")

        let data = try XCTUnwrap(PDFOps.optimize(document: document))
        let optimizedDocument = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertFalse((optimizedDocument.string ?? "").contains("Hidden optimized text"))
        XCTAssertTrue(optimizedDocument.page(at: 0)?.annotations.isEmpty ?? false)
    }

    func testPrivacyPreservingExportDropsSelectionHelperAndRestoresSource() throws {
        let document = try makeTextBackedDocument(text: "Selected annotation export")
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 24, y: 24, width: 80, height: 44),
                                 forType: .square,
                                 withProperties: nil)
        note.contents = "Persistent note"
        page.addAnnotation(note)
        let selectionHelper = SelectionAnnotation(bounds: note.bounds, forType: .square, withProperties: nil)
        page.addAnnotation(selectionHelper)

        let exportDocument = try PDFOps.privacyPreservingDocumentForExport(document)

        let exportedPage = try XCTUnwrap(exportDocument.page(at: 0))
        XCTAssertEqual(exportedPage.annotations.filter { !($0 is SelectionAnnotation) }.count, 1)
        XCTAssertTrue(exportedPage.annotations.contains { $0.contents == "Persistent note" })
        XCTAssertFalse(exportedPage.annotations.contains { $0 is SelectionAnnotation })
        XCTAssertTrue(page.annotations.contains { $0 === selectionHelper })
        XCTAssertEqual(page.annotations.filter { !($0 is SelectionAnnotation) }.count, 1)
    }

    func testMetadataCleanedDataRemovesOutboundMetadataWithoutMutatingSource() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Metadata clean")
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Secret Title",
            PDFDocumentAttribute.authorAttribute: "Secret Author",
        ]

        let data = try PDFOps.metadataCleanedData(document: document, sourceURL: url)
        let cleanedDocument = try XCTUnwrap(PDFDocument(data: data))
        let rawOutput = String(data: data, encoding: .isoLatin1) ?? ""

        XCTAssertEqual(cleanedDocument.pageCount, 1)
        XCTAssertNil(cleanedDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute])
        XCTAssertNil(cleanedDocument.documentAttributes?[PDFDocumentAttribute.authorAttribute])
        XCTAssertFalse(rawOutput.contains("Secret Title"))
        XCTAssertFalse(rawOutput.contains("Secret Author"))
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Secret Title")
    }

    func testMetadataCleanedDataFlattensReplacementTextBeforeExport() throws {
        let document = try makeTextBackedDocument(text: "Hidden metadata text")
        addReplacementTextAnnotations(to: document, replacement: "Public metadata text")

        let data = try PDFOps.metadataCleanedData(document: document)
        let cleanedDocument = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertFalse((cleanedDocument.string ?? "").contains("Hidden metadata text"))
        XCTAssertTrue(cleanedDocument.page(at: 0)?.annotations.isEmpty ?? false)
    }

    func testPrivacyPreservingSnapshotCreatesUnlockedCopyForEncryptedDocumentWithoutReplacementText() throws {
        let document = try makeTextBackedDocument(text: "Encrypted snapshot text")
        let encryptedData = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: "user-pass"))
        let encryptedDocument = try XCTUnwrap(PDFDocument(data: encryptedData))
        XCTAssertTrue(encryptedDocument.unlock(withPassword: "user-pass"))

        let snapshot = try PDFOps.privacyPreservingSnapshot(document: encryptedDocument)

        XCTAssertFalse(snapshot.isEncrypted)
        XCTAssertFalse(snapshot.isLocked)
        XCTAssertEqual(snapshot.pageCount, 1)
        XCTAssertNotNil(snapshot.page(at: 0))
        XCTAssertNotNil(snapshot.dataRepresentation())
        XCTAssertTrue((snapshot.string ?? "").contains("Encrypted snapshot text"))
    }

    func testPrivacyPreservingSnapshotPreservesOutlineForEncryptedDocument() throws {
        let document = try makeTextBackedDocument(text: "Encrypted outline text")
        let page = try XCTUnwrap(document.page(at: 0))
        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "Chapter 1"
        child.destination = PDFDestination(page: page, at: CGPoint(x: 24, y: 120))
        root.insertChild(child, at: 0)
        document.outlineRoot = root
        let encryptedData = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: "user-pass"))
        let encryptedDocument = try XCTUnwrap(PDFDocument(data: encryptedData))
        XCTAssertTrue(encryptedDocument.unlock(withPassword: "user-pass"))

        let snapshot = try PDFOps.privacyPreservingSnapshot(document: encryptedDocument)

        let copiedChild = try XCTUnwrap(snapshot.outlineRoot?.child(at: 0))
        XCTAssertEqual(copiedChild.label, "Chapter 1")
        XCTAssertTrue(copiedChild.destination?.page === snapshot.page(at: 0))
    }

    func testPrivacyPreservingSnapshotPreservesURLBookmarkActionsForEncryptedDocument() throws {
        let document = try makeTextBackedDocument(text: "Encrypted URL outline text")
        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "Source link"
        child.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/source")))
        root.insertChild(child, at: 0)
        document.outlineRoot = root
        let encryptedData = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: "user-pass"))
        let encryptedDocument = try XCTUnwrap(PDFDocument(data: encryptedData))
        XCTAssertTrue(encryptedDocument.unlock(withPassword: "user-pass"))

        let snapshot = try PDFOps.privacyPreservingSnapshot(document: encryptedDocument)

        let copiedChild = try XCTUnwrap(snapshot.outlineRoot?.child(at: 0))
        let action = try XCTUnwrap(copiedChild.action as? PDFActionURL)
        XCTAssertEqual(copiedChild.label, "Source link")
        XCTAssertEqual(action.url, URL(string: "https://example.com/source"))
    }

    func testMetadataCleanedDataExportsUnlockedEncryptedDocumentWithoutReplacementText() throws {
        let document = try makeTextBackedDocument(text: "Encrypted metadata text")
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Private encrypted title",
        ]
        let encryptedData = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: "user-pass"))
        let encryptedDocument = try XCTUnwrap(PDFDocument(data: encryptedData))
        XCTAssertTrue(encryptedDocument.unlock(withPassword: "user-pass"))

        let data = try PDFOps.metadataCleanedData(document: encryptedDocument)
        let cleanedDocument = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertFalse(cleanedDocument.isEncrypted)
        XCTAssertEqual(cleanedDocument.pageCount, 1)
        XCTAssertTrue((cleanedDocument.string ?? "").contains("Encrypted metadata text"))
        XCTAssertNil(cleanedDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute])
    }

    func testMetadataCleanedDataValidatesUnlockedSnapshotWhenSourceURLIsLockedEncryptedPDF() throws {
        let source = try makeTextBackedDocument(text: "Locked source metadata text")
        let encryptedData = try XCTUnwrap(PDFSecurity.encrypt(document: source, userPassword: "user-pass"))
        let encryptedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try encryptedData.write(to: encryptedURL)
        defer { try? FileManager.default.removeItem(at: encryptedURL) }

        let lockedSource = try XCTUnwrap(PDFDocument(url: encryptedURL))
        XCTAssertTrue(lockedSource.isLocked)
        let unlockedDocument = try XCTUnwrap(PDFDocument(data: encryptedData))
        XCTAssertTrue(unlockedDocument.unlock(withPassword: "user-pass"))

        let data = try PDFOps.metadataCleanedData(document: unlockedDocument, sourceURL: encryptedURL)
        let cleanedDocument = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertFalse(cleanedDocument.isEncrypted)
        XCTAssertEqual(cleanedDocument.pageCount, 1)
        XCTAssertTrue((cleanedDocument.string ?? "").contains("Locked source metadata text"))
    }

    func testExtractTextForExportBlocksReplacementTextDocuments() throws {
        let document = try makeTextBackedDocument(text: "Hidden text export text")
        addReplacementTextAnnotations(to: document, replacement: "Public text export text")

        XCTAssertThrowsError(try PDFOps.extractTextForExport(document: document)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Text export is blocked"))
        }
    }

    func testExtractTextForExportKeepsPlainDocumentText() throws {
        let document = try makeTextBackedDocument(text: "Plain export text")

        let text = try PDFOps.extractTextForExport(document: document)

        XCTAssertTrue(text.contains("--- Page 1 ---"))
        XCTAssertTrue(text.contains("Plain export text"))
    }

    func testFlattenedDataBakesAnnotationsIntoNonEditablePages() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Flatten me", size: CGSize(width: 200, height: 200))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 80, height: 80),
                                       forType: .square,
                                       withProperties: nil)
        annotation.color = .systemRed
        annotation.interiorColor = .systemRed
        page.addAnnotation(annotation)

        let data = try PDFOps.flattenedData(document: document)
        let flattenedDocument = try XCTUnwrap(PDFDocument(data: data))
        let flattenedPage = try XCTUnwrap(flattenedDocument.page(at: 0))

        XCTAssertEqual(flattenedDocument.pageCount, 1)
        XCTAssertTrue(flattenedPage.annotations.isEmpty)
        XCTAssertEqual(page.annotations.count, 1)
    }

    func testFlattenedDataPreservesOutlineDestinations() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Outline me", size: CGSize(width: 200, height: 200))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let root = PDFOutline()
        let child = PDFOutline()
        child.label = "Chapter 1"
        child.destination = PDFDestination(page: page, at: CGPoint(x: 20, y: 180))
        root.insertChild(child, at: 0)
        document.outlineRoot = root

        let data = try PDFOps.flattenedData(document: document)
        let flattenedDocument = try XCTUnwrap(PDFDocument(data: data))

        let copiedChild = try XCTUnwrap(flattenedDocument.outlineRoot?.child(at: 0))
        XCTAssertEqual(copiedChild.label, "Chapter 1")
        XCTAssertTrue(copiedChild.destination?.page === flattenedDocument.page(at: 0))
        XCTAssertEqual(copiedChild.destination?.point.x ?? -1, 20, accuracy: 0.5)
    }

    func testFlattenedDataPreservesPageRotation() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Rotate me", size: CGSize(width: 200, height: 100))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90

        let data = try PDFOps.flattenedData(document: document)
        let flattenedDocument = try XCTUnwrap(PDFDocument(data: data))
        let flattenedPage = try XCTUnwrap(flattenedDocument.page(at: 0))

        XCTAssertEqual(flattenedPage.rotation, 90)
        XCTAssertEqual(flattenedPage.bounds(for: .cropBox).width, page.bounds(for: .cropBox).width, accuracy: 0.5)
        XCTAssertEqual(flattenedPage.bounds(for: .cropBox).height, page.bounds(for: .cropBox).height, accuracy: 0.5)
    }

    func testFlattenedDataPreservesVisibleCropAreaOnly() throws {
        let image = NSImage(size: CGSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        NSColor.systemGreen.setFill()
        NSRect(x: 50, y: 50, width: 100, height: 100).fill()
        image.unlockFocus()

        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: image))
        page.setBounds(CGRect(x: 50, y: 50, width: 100, height: 100), for: .cropBox)
        document.insert(page, at: 0)

        let data = try PDFOps.flattenedData(document: document)
        let flattenedDocument = try XCTUnwrap(PDFDocument(data: data))
        let flattenedPage = try XCTUnwrap(flattenedDocument.page(at: 0))
        let flattenedBounds = flattenedPage.bounds(for: .mediaBox)
        let rendered = try XCTUnwrap(TestPDFRenderer.render(flattenedPage, size: CGSize(width: 100, height: 100)))
        let center = try XCTUnwrap(rendered.color(at: CGPoint(x: 50, y: 50)))

        XCTAssertEqual(flattenedBounds.width, 100, accuracy: 0.5)
        XCTAssertEqual(flattenedBounds.height, 100, accuracy: 0.5)
        let converted = center.usingColorSpace(.sRGB) ?? center
        XCTAssertGreaterThan(converted.greenComponent, 0.45)
        XCTAssertLessThan(converted.redComponent, 0.35)
    }

    func testFlattenedDataDrawsRequestedCropBox() throws {
        let document = PDFDocument()
        document.insert(DisplayBoxProbePage(), at: 0)

        let data = try PDFOps.flattenedData(document: document)
        let flattenedDocument = try XCTUnwrap(PDFDocument(data: data))
        let flattenedPage = try XCTUnwrap(flattenedDocument.page(at: 0))
        let rendered = try XCTUnwrap(TestPDFRenderer.render(flattenedPage, size: CGSize(width: 100, height: 100)))
        let center = try XCTUnwrap(rendered.color(at: CGPoint(x: 50, y: 50)))
        let converted = center.usingColorSpace(.sRGB) ?? center

        XCTAssertGreaterThan(converted.greenComponent, 0.45)
        XCTAssertLessThan(converted.redComponent, 0.35)
    }

    private func addReplacementTextAnnotations(to document: PDFDocument, replacement: String) {
        guard let page = document.page(at: 0) else { return }
        let cover = PDFAnnotation(bounds: CGRect(x: 20, y: 110, width: 260, height: 40),
                                  forType: .square,
                                  withProperties: nil)
        cover.color = .white
        cover.interiorColor = .white
        cover.userName = PDFOps.replacementTextAnnotationUserName
        page.addAnnotation(cover)

        let text = PDFAnnotation(bounds: CGRect(x: 20, y: 110, width: 260, height: 40),
                                 forType: .freeText,
                                 withProperties: nil)
        text.contents = replacement
        text.userName = PDFOps.replacementTextAnnotationUserName
        page.addAnnotation(text)
    }

    private func makeTextBackedDocument(text: String) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 240)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFOpsTests", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to create PDF context",
            ])
        }

        context.beginPDFPage(nil)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        NSColor.white.setFill()
        mediaBox.fill()
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
            ]
        ).draw(in: CGRect(x: 24, y: 120, width: 272, height: 40))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PDFDocument(data: data))
    }
}

private final class DisplayBoxProbePage: PDFPage {
    override func bounds(for box: PDFDisplayBox) -> CGRect {
        switch box {
        case .cropBox:
            CGRect(x: 50, y: 50, width: 100, height: 100)
        default:
            CGRect(x: 0, y: 0, width: 200, height: 200)
        }
    }

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        let fill = box == .cropBox ? NSColor.systemGreen.cgColor : NSColor.systemRed.cgColor
        context.setFillColor(fill)
        context.fill(bounds(for: box))
    }
}
