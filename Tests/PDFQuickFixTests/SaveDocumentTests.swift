import AppKit
import Combine
import PDFKit
@testable import PDFQuickFix
import PDFQuickFixKit
import XCTest

@MainActor
final class SaveDocumentTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testStudioPasswordPromptDocumentReplacementCannotWriteOrClobberReplacementURLs() throws {
        let sourceURL = try makeEncryptedTextBackedPDFURL(text: "Original protected source")
        let replacementURL = try makeTextBackedPDFURL(text: "Replacement source")
        defer { try? FileManager.default.removeItem(at: sourceURL); try? FileManager.default.removeItem(at: replacementURL) }
        let original = try Data(contentsOf: sourceURL)
        let replacement = try XCTUnwrap(PDFDocument(url: replacementURL))
        var controller: StudioController!
        controller = StudioController(passwordProvider: { _ in
            controller.setDocument(replacement, url: replacementURL)
            return "user-pass"
        })
        let source = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(source.unlock(withPassword: "user-pass"))
        controller.setDocument(source, url: sourceURL)

        XCTAssertFalse(controller.saveDocument(to: sourceURL))

        XCTAssertTrue(controller.document === replacement)
        XCTAssertEqual(controller.currentURL, replacementURL)
        XCTAssertEqual(controller.sourceURL, replacementURL)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    func testReaderPasswordPromptDocumentReplacementCannotWriteOrClobberReplacementURLs() throws {
        let sourceURL = try makeEncryptedTextBackedPDFURL(text: "Original reader source")
        let replacementURL = try makeTextBackedPDFURL(text: "Replacement reader source")
        defer { try? FileManager.default.removeItem(at: sourceURL); try? FileManager.default.removeItem(at: replacementURL) }
        let original = try Data(contentsOf: sourceURL)
        let replacement = try XCTUnwrap(PDFDocument(url: replacementURL))
        var controller: ReaderControllerPro!
        var shouldReplace = false
        controller = ReaderControllerPro(passwordProvider: { _ in
            if shouldReplace {
                controller.document = replacement
                controller.open(url: replacementURL)
            }
            return "user-pass"
        })
        let loaded = expectation(description: "Reader opened initial protected source")
        controller.$document.compactMap(\.self).first().sink { _ in loaded.fulfill() }.store(in: &cancellables)
        controller.open(url: sourceURL)
        wait(for: [loaded], timeout: 5)
        // A separately unlocked injected document has no cached verification credential.
        let source = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(source.unlock(withPassword: "user-pass"))
        controller.document = source
        shouldReplace = true
        let replaced = expectation(description: "Reader finished replacement open")
        controller.$currentURL.filter { $0 == replacementURL }.first().sink { _ in replaced.fulfill() }.store(in: &cancellables)

        controller.saveDocument()
        wait(for: [replaced], timeout: 5)

        XCTAssertEqual(controller.currentURL, replacementURL)
        XCTAssertEqual(controller.sourceURL, replacementURL)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        XCTAssertFalse(controller.log.contains("Saved"))
    }

    func testStudioSavePersistsBookmarkAddedToSourceBackedDocument() throws {
        let sourceURL = try makeTextBackedPDFURL(text: "Bookmark save text")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let controller = StudioController()
        controller.setDocument(try XCTUnwrap(PDFDocument(url: sourceURL)), url: sourceURL)

        controller.addOutline(title: "Saved chapter")
        XCTAssertEqual(controller.document?.outlineRoot?.numberOfChildren, 1)
        XCTAssertTrue(controller.saveDocument(to: sourceURL))

        let reloaded = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertEqual(reloaded.outlineRoot?.child(at: 0)?.label, "Saved chapter")
        XCTAssertTrue((reloaded.string ?? "").contains("Bookmark save text"))
    }

    func testStudioSavesBookmarkRenameDeleteUndoAndRedo() throws {
        let sourceURL = try makeTextBackedPDFURL(text: "Bookmark history")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let fresh = PDFDocument()
        let source = try XCTUnwrap(PDFDocument(url: sourceURL))
        fresh.insert(try XCTUnwrap(source.page(at: 0)?.copy() as? PDFPage), at: 0)
        let root = PDFOutline()
        let chapter = PDFOutline()
        chapter.label = "Draft"
        chapter.destination = PDFDestination(page: try XCTUnwrap(fresh.page(at: 0)), at: .zero)
        root.insertChild(chapter, at: 0)
        fresh.outlineRoot = root
        try PDFDocumentSerializer.write(fresh, to: sourceURL)
        let controller = StudioController()
        controller.setDocument(try XCTUnwrap(PDFDocument(url: sourceURL)), url: sourceURL)
        let row = try XCTUnwrap(controller.outlineRows.first)
        controller.renameOutline(row, title: "Final")
        try assertSavedOutlineLabels(["Final"], controller: controller, url: sourceURL)
        controller.undoLastEdit()
        try assertSavedOutlineLabels(["Draft"], controller: controller, url: sourceURL)
        controller.redoLastEdit()
        try assertSavedOutlineLabels(["Final"], controller: controller, url: sourceURL)
        controller.deleteOutline(row)
        try assertSavedOutlineLabels([], controller: controller, url: sourceURL)
        controller.undoLastEdit()
        try assertSavedOutlineLabels(["Final"], controller: controller, url: sourceURL)
        controller.redoLastEdit()
        try assertSavedOutlineLabels([], controller: controller, url: sourceURL)
    }

    func testStudioFailedSaveRestoresHelperAndKeepsSourceURLsAndBytes() throws {
        let sourceURL = try makeTextBackedPDFURL(text: "Failed save source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalBytes = try Data(contentsOf: sourceURL)
        let controller = StudioController()
        controller.attach(pdfView: PDFView())
        controller.setDocument(try XCTUnwrap(PDFDocument(url: sourceURL)), url: sourceURL)
        let note = try XCTUnwrap(EditingTools.addNote(in: controller.pdfView, text: "Selected unsaved note"))
        controller.selectAnnotation(note)
        let originalCount = controller.document?.page(at: 0)?.annotations.count
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("Sentinel".utf8).write(to: directory.appendingPathComponent("existing"))

        XCTAssertFalse(controller.saveDocument(to: directory))

        XCTAssertTrue(controller.selectedAnnotation === note)
        XCTAssertEqual(controller.document?.page(at: 0)?.annotations.count, originalCount)
        XCTAssertTrue(controller.document?.page(at: 0)?.annotations.contains { $0 is SelectionAnnotation } ?? false)
        XCTAssertEqual(controller.sourceURL, sourceURL)
        XCTAssertEqual(controller.currentURL, sourceURL)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertFalse(controller.logMessages.contains { $0.contains("Saved") })
        XCTAssertTrue(controller.logMessages.contains { $0.contains("Save blocked:") })
    }

    func testStudioEncryptedSaveReusesOnlyTheCurrentDocumentsOpenPassword() throws {
        let firstURL = try makeEncryptedTextBackedPDFURL(text: "First encrypted", userPassword: "first-pass")
        let secondURL = try makeEncryptedTextBackedPDFURL(text: "Second encrypted", userPassword: "second-pass")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        var requests: [URL] = []
        let controller = StudioController(passwordProvider: { url in
            requests.append(url)
            return url == firstURL ? "first-pass" : "second-pass"
        })
        let loaded = expectation(description: "Studio opened first encrypted source")
        controller.$document.compactMap(\.self).first().sink { _ in loaded.fulfill() }.store(in: &cancellables)
        controller.open(url: firstURL)
        wait(for: [loaded], timeout: 5)
        XCTAssertEqual(requests, [firstURL])
        XCTAssertTrue(controller.saveDocument(to: firstURL))
        XCTAssertEqual(requests, [firstURL], "A successful open credential should be reused in memory")

        let second = try XCTUnwrap(PDFDocument(url: secondURL))
        XCTAssertTrue(second.unlock(withPassword: "second-pass"))
        controller.setDocument(second, url: secondURL)
        XCTAssertTrue(controller.saveDocument(to: secondURL))
        XCTAssertEqual(requests, [firstURL, secondURL], "A replacement must not reuse the first document's password")
        controller.closeDocument()
        controller.setDocument(second, url: secondURL)
        XCTAssertTrue(controller.saveDocument(to: secondURL))
        XCTAssertEqual(requests, [firstURL, secondURL, secondURL], "Closing must discard the credential")
        let saved = try XCTUnwrap(PDFDocument(url: secondURL))
        XCTAssertTrue(saved.isLocked)
        XCTAssertFalse(saved.unlock(withPassword: "first-pass"))
        XCTAssertTrue(saved.unlock(withPassword: "second-pass"))
    }

    func testReaderEncryptedSaveReusesOpenPasswordAndPromptsForInjectedDocument() throws {
        let sourceURL = try makeEncryptedTextBackedPDFURL(text: "Reader protected source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var requests = 0
        let controller = ReaderControllerPro(passwordProvider: { _ in requests += 1; return "user-pass" })
        let loaded = expectation(description: "Reader opened protected source")
        controller.$document.compactMap(\.self).first().sink { _ in loaded.fulfill() }.store(in: &cancellables)
        controller.open(url: sourceURL)
        wait(for: [loaded], timeout: 5)
        controller.saveDocument()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(controller.log.hasPrefix("Saved"))
        controller.closeDocument()
        let injected = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(injected.unlock(withPassword: "user-pass"))
        controller.document = injected
        controller.saveDocument()
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(controller.log.hasPrefix("Saved"))
        let saved = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(saved.unlock(withPassword: "user-pass"))
    }

    func testStudioWrongSaveVerificationPasswordLeavesOriginalUnchanged() throws {
        let sourceURL = try makeEncryptedTextBackedPDFURL(text: "Protected source")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalBytes = try Data(contentsOf: sourceURL)
        let controller = StudioController(passwordProvider: { _ in "wrong-pass" })
        let document = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(document.unlock(withPassword: "user-pass"))
        controller.setDocument(document, url: sourceURL)

        XCTAssertFalse(controller.saveDocument(to: sourceURL))

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertFalse(controller.logMessages.contains { $0.contains("Saved") })
        XCTAssertTrue(controller.logMessages.contains { $0.contains("Save blocked:") })
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
        XCTAssertTrue(PDFOps.containsReplacementTextAnnotations(in: document), "Fixture must contain replacement annotations")
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
        let encryptedURL = try makeEncryptedTextBackedPDFURL(text: "Encrypted reader text", allowsCommenting: true)
        let originalBytes = try Data(contentsOf: encryptedURL)
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
        XCTAssertEqual(document.permissionsStatus, .user)
        XCTAssertTrue(PDFOps.containsReplacementTextAnnotations(in: document), "Fixture must exercise the encrypted replacement-text guard")
        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: encryptedURL))
        XCTAssertTrue(reloaded.isEncrypted)
        XCTAssertTrue(reloaded.isLocked)
        XCTAssertTrue(controller.log.contains("Save blocked"))
        XCTAssertTrue(controller.log.contains("after replacing text"))
        XCTAssertEqual(try Data(contentsOf: encryptedURL), originalBytes)
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
        let persistentSemanticCount = controller.document?.page(at: 0)?.annotations.filter { $0.type != "Popup" }.count
        controller.selectAnnotation(annotation)
        XCTAssertEqual(controller.document?.page(at: 0)?.annotations.count, persistentAnnotationCount + 1)

        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(reloaded.page(at: 0))
        // PDFKit may expose a Popup beside a Text note only in memory.
        XCTAssertEqual(page.annotations.filter { $0.type != "Popup" }.count, persistentSemanticCount)
        XCTAssertFalse(page.annotations.contains { $0.type == "Square" }, "Selection helper must not be saved")
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
        XCTAssertTrue(PDFOps.containsReplacementTextAnnotations(in: document), "Fixture must contain replacement annotations")
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
        let encryptedURL = try makeEncryptedTextBackedPDFURL(text: "Encrypted studio text", allowsCommenting: true)
        let originalBytes = try Data(contentsOf: encryptedURL)
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
        XCTAssertEqual(document.permissionsStatus, .user)
        XCTAssertTrue(PDFOps.containsReplacementTextAnnotations(in: document), "Fixture must exercise the encrypted replacement-text guard")
        controller.saveDocument()

        let reloaded = try XCTUnwrap(PDFDocument(url: encryptedURL))
        XCTAssertTrue(reloaded.isEncrypted)
        XCTAssertTrue(reloaded.isLocked)
        XCTAssertTrue(controller.logMessages.contains { $0.contains("Save blocked") })
        XCTAssertTrue(controller.logMessages.contains { $0.contains("after replacing text") })
        XCTAssertEqual(try Data(contentsOf: encryptedURL), originalBytes)
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

    private func assertSavedOutlineLabels(_ labels: [String], controller: StudioController, url: URL) throws {
        XCTAssertTrue(controller.saveDocument(to: url))
        let reloaded = try XCTUnwrap(PDFDocument(url: url))
        let root = reloaded.outlineRoot
        XCTAssertEqual((0 ..< (root?.numberOfChildren ?? 0)).map { root?.child(at: $0)?.label ?? "" }, labels)
    }

    private func makeEncryptedTextBackedPDFURL(text: String, userPassword: String = "user-pass", allowsCommenting: Bool = false) throws -> URL {
        let plainURL = try makeTextBackedPDFURL(text: text)
        let document = try XCTUnwrap(PDFDocument(url: plainURL))
        let encryptedData: Data
        if allowsCommenting {
            // Independent native fixture: this runtime expands commenting to
            // document-change permission, which the strict serializer rejects.
            // The save guard must be exercised by actual replacement annotations.
            encryptedData = try XCTUnwrap(document.dataRepresentation(options: [
                PDFDocumentWriteOption.userPasswordOption: userPassword,
                PDFDocumentWriteOption.ownerPasswordOption: "owner-\(userPassword)",
                PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: (1 << 1) | (1 << 6)),
            ]))
            let fixture = try XCTUnwrap(PDFDocument(data: encryptedData))
            XCTAssertTrue(fixture.isLocked)
            XCTAssertTrue(fixture.unlock(withPassword: userPassword))
            XCTAssertEqual(fixture.permissionsStatus, .user)
            XCTAssertTrue(fixture.allowsCommenting)
        } else {
            encryptedData = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: userPassword, ownerPassword: "owner-\(userPassword)"))
        }
        let encryptedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try encryptedData.write(to: encryptedURL)
        return encryptedURL
    }
}
