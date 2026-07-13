import AppKit
import Combine
import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class SaveDocumentTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testReaderSaveDocumentWritesBackToSourceURL() throws {
        let controller = ReaderControllerPro()
        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Reader save")
        let loaded = expectation(description: "Reader opened source PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in loaded.fulfill() }
            .store(in: &cancellables)

        controller.open(url: pdfURL)
        wait(for: [loaded], timeout: 5.0)

        EditingTools.addNote(in: controller.pdfView, text: "Saved note")
        if controller.pdfView == nil {
            let page = try XCTUnwrap(controller.document?.page(at: 0))
            let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 32, height: 32), forType: .text, withProperties: nil)
            note.contents = "Saved note"
            page.addAnnotation(note)
        }

        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(reloaded.page(at: 0))
        XCTAssertTrue(page.annotations.contains { $0.contents == "Saved note" })
        XCTAssertTrue(controller.log.contains("Saved"))
    }

    func testReaderSaveDocumentFlattensReplaceTextSoOriginalTextIsNotExtractable() throws {
        let controller = ReaderControllerPro()
        controller.pdfView = PDFView()
        let pdfURL = try makeTextBackedPDFURL(text: "Secret reader text")
        let loaded = expectation(description: "Reader opened source PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in loaded.fulfill() }
            .store(in: &cancellables)

        controller.open(url: pdfURL)
        wait(for: [loaded], timeout: 5.0)

        let document = try XCTUnwrap(controller.document)
        let pdfView = try XCTUnwrap(controller.pdfView)
        let selection = try makeFullDocumentSelection(in: document)
        pdfView.setCurrentSelection(selection, animate: false)
        controller.replaceSelectedText(with: "Public reader text")
        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertFalse((reloaded.string ?? "").contains("Secret reader text"))
        XCTAssertTrue(reloaded.page(at: 0)?.annotations.isEmpty ?? false)
        XCTAssertFalse((controller.document?.string ?? "").contains("Secret reader text"))
        XCTAssertTrue(controller.document?.page(at: 0)?.annotations.isEmpty ?? false)

        controller.saveDocument()
        let reloadedAfterSecondSave = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertFalse((reloadedAfterSecondSave.string ?? "").contains("Secret reader text"))
        XCTAssertTrue(reloadedAfterSecondSave.page(at: 0)?.annotations.isEmpty ?? false)
        XCTAssertTrue(controller.log.contains("Saved"))
    }

    func testReaderSaveDocumentDoesNotDropEncryptionWhenReplacementTextExists() throws {
        let controller = ReaderControllerPro(passwordProvider: { _ in "user-pass" })
        controller.pdfView = PDFView()
        let encryptedURL = try makeEncryptedTextBackedPDFURL(text: "Encrypted reader text")
        let loaded = expectation(description: "Reader opened encrypted PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in loaded.fulfill() }
            .store(in: &cancellables)

        controller.open(url: encryptedURL)
        wait(for: [loaded], timeout: 5.0)

        let document = try XCTUnwrap(controller.document)
        let pdfView = try XCTUnwrap(controller.pdfView)
        let selection = try makeFullDocumentSelection(in: document)
        pdfView.setCurrentSelection(selection, animate: false)
        controller.replaceSelectedText(with: "Public reader text")
        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: encryptedURL))
        XCTAssertTrue(reloaded.isEncrypted)
        XCTAssertTrue(reloaded.isLocked)
        XCTAssertTrue(controller.log.contains("Save blocked"))
    }

    func testStudioSaveDocumentWritesBackToSourceURL() throws {
        let controller = StudioController()
        controller.attach(pdfView: PDFView())
        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Studio save")
        let loaded = expectation(description: "Studio opened source PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in loaded.fulfill() }
            .store(in: &cancellables)

        controller.open(url: pdfURL)
        wait(for: [loaded], timeout: 5.0)

        EditingTools.addNote(in: controller.pdfView, text: "Studio saved note")
        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(reloaded.page(at: 0))
        XCTAssertTrue(page.annotations.contains { $0.contents == "Studio saved note" })
        XCTAssertTrue(controller.logMessages.contains { $0.contains("Saved") })
    }

    func testStudioSaveDocumentDoesNotPersistSelectionHelperAnnotation() throws {
        let controller = StudioController()
        controller.attach(pdfView: PDFView())
        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Studio selected save")
        let loaded = expectation(description: "Studio opened source PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in loaded.fulfill() }
            .store(in: &cancellables)

        controller.open(url: pdfURL)
        wait(for: [loaded], timeout: 5.0)

        let annotation = try XCTUnwrap(EditingTools.addNote(in: controller.pdfView, text: "Selected note"))
        let persistentAnnotationCount = try XCTUnwrap(controller.document?.page(at: 0)?.annotations.count)
        controller.selectAnnotation(annotation)
        XCTAssertEqual(controller.document?.page(at: 0)?.annotations.count, persistentAnnotationCount + 1)

        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(reloaded.page(at: 0))
        XCTAssertEqual(page.annotations.count, persistentAnnotationCount)
        XCTAssertTrue(page.annotations.contains { $0.contents == "Selected note" })
        XCTAssertNotNil(controller.selectedAnnotation)
        XCTAssertEqual(controller.document?.page(at: 0)?.annotations.count, persistentAnnotationCount + 1)
    }

    func testStudioSaveDocumentFlattensReplaceTextSoOriginalTextIsNotExtractable() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let pdfURL = try makeTextBackedPDFURL(text: "Secret studio text")
        let loaded = expectation(description: "Studio opened source PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in loaded.fulfill() }
            .store(in: &cancellables)

        controller.open(url: pdfURL)
        wait(for: [loaded], timeout: 5.0)

        let document = try XCTUnwrap(controller.document)
        let selection = try makeFullDocumentSelection(in: document)
        pdfView.setCurrentSelection(selection, animate: false)
        controller.replaceSelectedText(with: "Public studio text")
        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertFalse((reloaded.string ?? "").contains("Secret studio text"))
        XCTAssertTrue(reloaded.page(at: 0)?.annotations.isEmpty ?? false)
        XCTAssertFalse((controller.document?.string ?? "").contains("Secret studio text"))
        XCTAssertTrue(controller.document?.page(at: 0)?.annotations.isEmpty ?? false)

        controller.saveDocument()
        let reloadedAfterSecondSave = try XCTUnwrap(PDFDocument(url: pdfURL))
        XCTAssertFalse((reloadedAfterSecondSave.string ?? "").contains("Secret studio text"))
        XCTAssertTrue(reloadedAfterSecondSave.page(at: 0)?.annotations.isEmpty ?? false)
        XCTAssertTrue(controller.logMessages.contains { $0.contains("Saved") })
    }

    func testStudioSaveToDestinationFlattensRedactionSoOriginalTextIsNotExtractable() throws {
        let controller = StudioController()
        let sourceURL = try makeTextBackedPDFURL(text: "Secret studio redaction")
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        controller.setDocument(try XCTUnwrap(PDFDocument(url: sourceURL)), url: sourceURL)

        let document = try XCTUnwrap(controller.document)
        let selection = try makeFullDocumentSelection(in: document)
        let page = try XCTUnwrap(document.page(at: 0))
        let cover = PDFAnnotation(
            bounds: selection.bounds(for: page).insetBy(dx: -1, dy: -1),
            forType: .square,
            withProperties: nil
        )
        cover.color = .black
        cover.interiorColor = .black
        cover.userName = PDFOps.replacementTextAnnotationUserName
        let border = PDFBorder()
        border.lineWidth = 0
        cover.border = border
        page.addAnnotation(cover)

        XCTAssertTrue(controller.saveDocument(to: destinationURL))

        let reloaded = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertFalse((reloaded.string ?? "").contains("Secret studio redaction"))
        XCTAssertTrue(reloaded.page(at: 0)?.annotations.isEmpty ?? false)
    }

    func testStudioSaveToDestinationThenSaveDoesNotOverwriteOriginal() throws {
        let controller = StudioController()
        let sourceURL = try TestPDFBuilder.makeSimplePDF(text: "Original studio file")
        let originalData = try Data(contentsOf: sourceURL)
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        controller.setDocument(try XCTUnwrap(PDFDocument(url: sourceURL)), url: sourceURL)

        XCTAssertTrue(controller.saveDocument(to: destinationURL))
        let note = PDFAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 32, height: 32),
            forType: .text,
            withProperties: nil
        )
        note.contents = "Saved only to new destination"
        try XCTUnwrap(controller.document?.page(at: 0)).addAnnotation(note)
        controller.saveDocument()

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
        let destination = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertTrue(destination.page(at: 0)?.annotations.contains {
            $0.contents == "Saved only to new destination"
        } ?? false)
        XCTAssertEqual(controller.currentURL, destinationURL)
        XCTAssertEqual(controller.sourceURL, destinationURL)
    }

    func testStudioSaveDocumentDoesNotDropEncryptionWhenReplacementTextExists() throws {
        let controller = StudioController(passwordProvider: { _ in "user-pass" })
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let encryptedURL = try makeEncryptedTextBackedPDFURL(text: "Encrypted studio text")
        let loaded = expectation(description: "Studio opened encrypted PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in loaded.fulfill() }
            .store(in: &cancellables)

        controller.open(url: encryptedURL)
        wait(for: [loaded], timeout: 5.0)

        let document = try XCTUnwrap(controller.document)
        let selection = try makeFullDocumentSelection(in: document)
        pdfView.setCurrentSelection(selection, animate: false)
        controller.replaceSelectedText(with: "Public studio text")
        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: encryptedURL))
        XCTAssertTrue(reloaded.isEncrypted)
        XCTAssertTrue(reloaded.isLocked)
        XCTAssertTrue(controller.logMessages.contains { $0.contains("Save blocked") })
    }

    private func makeFullDocumentSelection(in document: PDFDocument) throws -> PDFSelection {
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string)
        return try XCTUnwrap(document.selection(from: page,
                                                atCharacterIndex: 0,
                                                to: page,
                                                atCharacterIndex: text.count - 1))
    }

    private func makeTextBackedPDFURL(text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 240)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "SaveDocumentTests", code: -1, userInfo: [
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

        return url
    }

    private func makeEncryptedTextBackedPDFURL(text: String) throws -> URL {
        let plainURL = try makeTextBackedPDFURL(text: text)
        let document = try XCTUnwrap(PDFDocument(url: plainURL))
        let encryptedData = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: "user-pass"))
        let encryptedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try encryptedData.write(to: encryptedURL)
        return encryptedURL
    }
}
