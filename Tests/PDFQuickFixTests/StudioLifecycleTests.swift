import AppKit
import Combine
import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class StudioLifecycleTests: XCTestCase {
    private var subscriptions: Set<AnyCancellable> = []

    override func tearDown() {
        subscriptions.removeAll()
        super.tearDown()
    }

    func testCancelCloseAndOpenRetainDocumentEditsAndUndo() throws {
        let fixture = fixture(discardDecision: { _ in .cancel })
        let source = temporaryURL()
        fixture.controller.setDocument(fixture.document, url: source)
        addNote(to: fixture)

        fixture.controller.closeDocument()
        fixture.controller.open(url: temporaryURL())

        XCTAssertTrue(fixture.controller.document === fixture.document)
        XCTAssertEqual(fixture.controller.sourceURL, source)
        XCTAssertTrue(fixture.controller.hasUnsavedChanges)
        XCTAssertFalse(fixture.controller.isDocumentLoading)
        fixture.controller.undoLastEdit()
        XCTAssertFalse(fixture.page.annotations.contains { $0.contents == "Unsaved note" })
    }

    func testCancelledSaveAsAndFailedSaveCannotAuthorizeClose() throws {
        let cancelled = fixture(discardDecision: { _ in .save }, saveDestination: { _ in nil })
        addNote(to: cancelled)
        XCTAssertEqual(cancelled.controller.saveAsOutcome(), .cancelled)
        XCTAssertNil(cancelled.controller.authorizeDiscardingChanges())
        cancelled.controller.closeDocument()
        XCTAssertTrue(cancelled.controller.document === cancelled.document)
        XCTAssertTrue(cancelled.controller.hasUnsavedChanges)

        let failed = fixture(discardDecision: { _ in .save })
        let missingParent = temporaryURL().appendingPathComponent("output.pdf")
        failed.controller.setDocument(failed.document, url: missingParent)
        addNote(to: failed)
        XCTAssertEqual(failed.controller.saveDocumentOutcome(), .failed)
        XCTAssertNil(failed.controller.authorizeDiscardingChanges())
        XCTAssertTrue(failed.controller.document === failed.document)
        XCTAssertTrue(failed.controller.hasUnsavedChanges)
    }

    func testSuccessfulSaveFlushesNativeValueAndLateKVODoesNotRedirty() async throws {
        let fixture = fixture(discardDecision: { _ in .cancel })
        let output = temporaryURL()
        defer { try? FileManager.default.removeItem(at: output) }
        fixture.text.widgetStringValue = "Saved native edit"

        XCTAssertTrue(fixture.controller.saveDocument(to: output))
        XCTAssertFalse(fixture.controller.hasUnsavedChanges)
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(fixture.controller.hasUnsavedChanges)
        let reopened = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first { $0.fieldName == "Native field" }?.widgetStringValue,
                       "Saved native edit")
    }

    func testNativeFieldIsFlushedBeforeCloseDecision() {
        var decisions = 0
        let fixture = fixture(discardDecision: { _ in decisions += 1; return .cancel })
        fixture.text.widgetStringValue = "Native edit queued before close"

        fixture.controller.closeDocument()

        XCTAssertEqual(decisions, 1)
        XCTAssertTrue(fixture.controller.document === fixture.document)
        XCTAssertTrue(fixture.controller.hasUnsavedChanges)
        XCTAssertEqual(fixture.text.widgetStringValue, "Native edit queued before close")
    }

    func testSaveAsCannotWriteAfterReentrantEditInDestinationPrompt() {
        let output = temporaryURL()
        var controller: StudioController!
        controller = StudioController(discardDecision: { _ in .cancel }, saveDestination: { _ in
            controller.addOutline(title: "Edit during Save As")
            return output
        }, errorPresenter: { _ in })
        let fixture = fixture(controller: controller)
        addNote(to: fixture)

        XCTAssertEqual(controller.saveAsOutcome(), .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(controller.document === fixture.document)
        XCTAssertTrue(controller.hasUnsavedChanges)
        XCTAssertEqual(fixture.document.outlineRoot?.child(at: 0)?.label, "Edit during Save As")
    }

    func testPasswordVerificationPromptEditKeepsDestinationAndDirtyDocument() throws {
        let source = try encryptedPDF()
        let output = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let sentinel = Data("existing destination".utf8)
        try sentinel.write(to: output)
        let document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(document.unlock(withPassword: "user-pass"))
        XCTAssertEqual(document.permissionsStatus, .user)
        var passwordRequests = 0
        var controller: StudioController!
        controller = StudioController(passwordProvider: { _ in
            passwordRequests += 1
            controller.addOutline(title: "Edit during password verification")
            return "user-pass"
        }, discardDecision: { _ in .cancel }, errorPresenter: { _ in })
        let view = LifecyclePDFView()
        controller.attach(pdfView: view)
        controller.setDocument(document, url: source)
        controller.addOutline(title: "Initial unsaved edit")

        XCTAssertFalse(controller.saveDocument(to: output))
        XCTAssertEqual(passwordRequests, 1)
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertTrue(controller.document === document)
        XCTAssertTrue(controller.hasUnsavedChanges)
    }

    func testCancelledSavePasswordHasExplicitOutcomeAndKeepsDirtyDocument() throws {
        let source = try encryptedPDF()
        let output = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        let document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(document.unlock(withPassword: "user-pass"))
        XCTAssertEqual(document.permissionsStatus, .user)
        var passwordRequests = 0
        let controller = StudioController(passwordProvider: { _ in passwordRequests += 1; return nil }, discardDecision: { _ in .save },
                                          errorPresenter: { _ in })
        let view = LifecyclePDFView()
        controller.attach(pdfView: view)
        controller.setDocument(document, url: output)
        controller.addOutline(title: "Unsaved protected edit")

        XCTAssertEqual(controller.saveDocumentOutcome(), .cancelled)
        XCTAssertEqual(passwordRequests, 1)
        XCTAssertNil(controller.authorizeDiscardingChanges())
        XCTAssertEqual(passwordRequests, 2)
        XCTAssertTrue(controller.document === document)
        XCTAssertTrue(controller.hasUnsavedChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testFailedReplacementPreservesSourceScopeDirtyDocumentAndUndo() throws {
        let failed = expectation(description: "Candidate open failed")
        let controller = StudioController(repairSourceURL: { $0 }, discardDecision: { _ in .discard },
                                          errorPresenter: { _ in failed.fulfill() })
        let view = LifecyclePDFView()
        controller.attach(pdfView: view)
        let initial = try TestPDFBuilder.makeSimplePDF(text: "Original studio document")
        let broken = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: initial)
            try? FileManager.default.removeItem(at: broken)
        }
        try Data("not a PDF".utf8).write(to: broken)
        open(initial, with: controller)
        let original = try XCTUnwrap(controller.document)
        let page = try XCTUnwrap(original.page(at: 0))
        let note = try XCTUnwrap(EditingTools.addNote(in: view, text: "Retained edit"))
        controller.registerAnnotationAddition(note)
        XCTAssertTrue(controller.hasActiveSecurityScope)

        controller.open(url: broken)
        wait(for: [failed], timeout: 5)

        XCTAssertTrue(controller.document === original)
        XCTAssertTrue(view.document === original)
        XCTAssertEqual(controller.sourceURL, initial)
        XCTAssertTrue(controller.hasActiveSecurityScope)
        XCTAssertTrue(controller.hasUnsavedChanges)
        XCTAssertFalse(controller.isDocumentLoading)
        controller.undoLastEdit()
        XCTAssertFalse(page.annotations.contains { $0 === note })
    }

    func testPasswordCancelledReplacementPreservesOriginalAndUndo() throws {
        let controller = StudioController(passwordProvider: { _ in nil }, repairSourceURL: { $0 },
                                          discardDecision: { _ in .discard }, errorPresenter: { _ in })
        let view = LifecyclePDFView()
        controller.attach(pdfView: view)
        let initial = try TestPDFBuilder.makeSimplePDF(text: "Original studio document")
        let encrypted = try encryptedPDF()
        defer {
            try? FileManager.default.removeItem(at: initial)
            try? FileManager.default.removeItem(at: encrypted)
        }
        open(initial, with: controller)
        let original = try XCTUnwrap(controller.document)
        let note = try XCTUnwrap(EditingTools.addNote(in: view, text: "Retained password-cancel edit"))
        controller.registerAnnotationAddition(note)
        let cancelled = expectation(description: "Password-cancelled candidate settled")
        controller.$logMessages.first { $0.contains { $0.contains("password required") } }
            .sink { _ in cancelled.fulfill() }.store(in: &subscriptions)

        controller.open(url: encrypted)
        wait(for: [cancelled], timeout: 5)

        XCTAssertTrue(controller.document === original)
        XCTAssertEqual(controller.sourceURL, initial)
        XCTAssertTrue(controller.hasActiveSecurityScope)
        XCTAssertTrue(controller.hasUnsavedChanges)
        XCTAssertFalse(controller.isDocumentLoading)
        controller.undoLastEdit()
        XCTAssertFalse(original.page(at: 0)?.annotations.contains { $0 === note } ?? true)
    }

    func testEditDuringAsyncOpenRejectsCandidateWithoutLosingNewEdit() throws {
        let candidate = try TestPDFBuilder.makeSimplePDF(text: "Replacement candidate")
        defer { try? FileManager.default.removeItem(at: candidate) }
        let started = expectation(description: "Repair started off-main")
        let release = DispatchSemaphore(value: 0)
        let controller = StudioController(repairSourceURL: { url in
            started.fulfill()
            release.wait()
            return url
        }, discardDecision: { _ in .discard }, errorPresenter: { _ in })
        let fixture = fixture(controller: controller)
        addNote(to: fixture)
        let cancelled = expectation(description: "Changed revision rejected at commit")
        controller.$logMessages.first { $0.contains { $0.contains("current document changed while loading") } }
            .sink { _ in cancelled.fulfill() }.store(in: &subscriptions)

        controller.open(url: candidate)
        wait(for: [started], timeout: 5)
        controller.addOutline(title: "Edit while candidate loads")
        release.signal()
        wait(for: [cancelled], timeout: 5)

        XCTAssertTrue(controller.document === fixture.document)
        XCTAssertTrue(controller.hasUnsavedChanges)
        XCTAssertFalse(controller.isDocumentLoading)
        XCTAssertEqual(fixture.document.outlineRoot?.child(at: 0)?.label, "Edit while candidate loads")
    }

    func testPendingNativeEditIsCommittedAndRejectsAsyncReplacement() throws {
        try assertAsyncReplacementPreservesNativeEditor(refusesCommit: false)
    }

    func testNativeEditorRefusalRejectsAsyncReplacement() throws {
        try assertAsyncReplacementPreservesNativeEditor(refusesCommit: true)
    }

    func testViewDetachCommitsPendingNativeEditBeforeObservationEnds() {
        let fixture = fixture(discardDecision: { _ in .cancel })
        let window = LifecycleEditingWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                             styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = fixture.view
        defer { window.resignEditor = nil; window.contentView = nil }
        var commitRequests = 0
        window.resignEditor = {
            commitRequests += 1
            fixture.text.widgetStringValue = "Committed before detach"
            return true
        }

        XCTAssertTrue(fixture.controller.detach(pdfView: fixture.view))

        XCTAssertEqual(commitRequests, 1)
        XCTAssertNil(fixture.controller.pdfView)
        XCTAssertTrue(fixture.controller.document === fixture.document)
        XCTAssertEqual(fixture.text.widgetStringValue, "Committed before detach")
        XCTAssertTrue(fixture.controller.hasUnsavedChanges)
    }

    func testViewDetachRefusalPreservesViewAndObservation() {
        let fixture = fixture(discardDecision: { _ in .cancel })
        let window = LifecycleEditingWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                             styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = fixture.view
        defer { window.resignEditor = nil; window.contentView = nil }
        window.resignEditor = { false }

        XCTAssertFalse(fixture.controller.detach(pdfView: fixture.view))

        XCTAssertTrue(fixture.controller.pdfView === fixture.view)
        XCTAssertTrue(fixture.view.document === fixture.document)
        fixture.text.widgetStringValue = "Edit after refused detach"
        fixture.controller.flushNativeChanges()
        XCTAssertTrue(fixture.controller.hasUnsavedChanges)
    }

    func testMutationFamiliesDirtyAndUndoDoesNotClaimClean() {
        let mutations: [(String, (StudioController) -> Void)] = [
            ("rotation", { $0.rotateCurrentPageRight() }),
            ("page insertion", { _ = $0.insertBlankPage() }),
            ("bookmark", { $0.addOutline(title: "Chapter") }),
            ("metadata", { $0.applyMetadata(DocumentMetadataDraft(title: "Updated title")) }),
            ("form creation", { $0.addFormField(kind: .checkbox, name: "Approved", rect: CGRect(x: 20, y: 90, width: 24, height: 24)) }),
            ("crop", { try? $0.crop(inset: 5, target: .allPages) }),
        ]
        for (name, mutate) in mutations {
            let fixture = fixture(discardDecision: { _ in .cancel })
            mutate(fixture.controller)
            XCTAssertTrue(fixture.controller.hasUnsavedChanges, name)
            fixture.controller.undoLastEdit()
            XCTAssertTrue(fixture.controller.hasUnsavedChanges, "Undo stays conservatively dirty: \(name)")
        }
    }

    func testReadingSelectionAndNoOpMetadataRemainClean() {
        var decisions = 0
        let fixture = fixture(discardDecision: { _ in decisions += 1; return .cancel })
        fixture.controller.clearMetadata()
        fixture.controller.movePage(at: 0, to: 0)
        fixture.controller.find("   ")
        fixture.controller.goTo(page: 0)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: fixture.view)
        fixture.controller.flushNativeChanges()

        XCTAssertFalse(fixture.controller.hasUnsavedChanges)
        XCTAssertNotNil(fixture.controller.authorizeDiscardingChanges())
        XCTAssertEqual(decisions, 0)
    }

    func testQueuedFindMatchesCannotSurviveClearNewQueryOrReplacement() async throws {
        let url = try searchablePDF(text: "Needle")
        defer { try? FileManager.default.removeItem(at: url) }
        for action in 0 ..< 3 {
            let controller = StudioController(discardDecision: { _ in .cancel }, errorPresenter: { _ in })
            let document = try XCTUnwrap(PDFDocument(url: url))
            controller.setDocument(document)
            let selection = try XCTUnwrap(document.findString("Needle", withOptions: []).first)
            XCTAssertEqual(selection.string, "Needle")
            controller.find("Needle")
            NotificationCenter.default.post(name: .PDFDocumentDidFindMatch, object: document,
                                            userInfo: ["PDFDocumentFoundSelection": selection])
            if action == 0 { controller.find("") }
            if action == 1 { controller.find("Absent query") }
            if action == 2 { controller.setDocument(PDFDocument()) }
            await Task.yield()
            await Task.yield()
            XCTAssertTrue(controller.searchMatches.isEmpty, "Stale queued selection for action \(action)")
            XCTAssertNil(controller.currentMatchIndex)
            XCTAssertFalse(controller.hasUnsavedChanges)
        }
    }

    func testDebouncedSearchCannotStartOnReplacementDocument() throws {
        let url = try searchablePDF(text: "Needle")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = StudioController(discardDecision: { _ in .cancel }, errorPresenter: { _ in })
        controller.setDocument(try XCTUnwrap(PDFDocument(url: url)))
        controller.updateSearchQueryDebounced("Needle")
        controller.setDocument(try XCTUnwrap(PDFDocument(url: url)))
        let elapsed = expectation(description: "Cancelled debounce deadline passed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { elapsed.fulfill() }
        wait(for: [elapsed], timeout: 5)
        XCTAssertTrue(controller.searchMatches.isEmpty)
        XCTAssertNil(controller.currentMatchIndex)
        XCTAssertEqual(controller.searchQuery, "")
    }

    private func open(_ url: URL, with controller: StudioController) {
        let opened = expectation(description: "Initial source adopted")
        controller.$sourceURL.first { $0 == url }.sink { _ in opened.fulfill() }.store(in: &subscriptions)
        controller.open(url: url)
        wait(for: [opened], timeout: 5)
    }

    private func assertAsyncReplacementPreservesNativeEditor(refusesCommit: Bool) throws {
        let candidate = try TestPDFBuilder.makeSimplePDF(text: "Replacement candidate")
        defer { try? FileManager.default.removeItem(at: candidate) }
        let started = expectation(description: "Candidate repair paused")
        let release = DispatchSemaphore(value: 0)
        let controller = StudioController(repairSourceURL: { url in
            started.fulfill()
            release.wait()
            return url
        }, discardDecision: { _ in .discard }, errorPresenter: { _ in })
        let fixture = fixture(controller: controller)
        let window = LifecycleEditingWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                             styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = fixture.view
        XCTAssertTrue(fixture.view.window === window)
        defer { window.resignEditor = nil; window.contentView = nil }

        controller.open(url: candidate)
        wait(for: [started], timeout: 5)
        // The field editor owns text that is not in the PDF model yet. Arm only
        // after initial transition authorization, so adoption must commit it again.
        var commitRequests = 0
        window.resignEditor = {
            commitRequests += 1
            guard !refusesCommit else { return false }
            fixture.text.widgetStringValue = "Pending native editor text"
            return true
        }
        let settled = expectation(description: "Candidate adoption settled")
        controller.$logMessages.first { messages in
            messages.contains { $0.contains("Opened") || $0.contains("Open cancelled") }
        }.sink { _ in settled.fulfill() }.store(in: &subscriptions)
        release.signal()
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(commitRequests, 1, "Adoption must ask the active editor to commit")
        XCTAssertTrue(controller.document === fixture.document)
        XCTAssertTrue(fixture.view.document === fixture.document)
        XCTAssertFalse(controller.isDocumentLoading)
        XCTAssertEqual(fixture.text.widgetStringValue, refusesCommit ? "Initial" : "Pending native editor text")
        XCTAssertEqual(controller.hasUnsavedChanges, !refusesCommit)
    }

    private func encryptedPDF() throws -> URL {
        let source = try TestPDFBuilder.makeSimplePDF(text: "Encrypted candidate")
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let bytes = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: "user-pass", ownerPassword: "owner-pass"))
        let url = temporaryURL()
        try bytes.write(to: url)
        return url
    }

    private func searchablePDF(text: String) throws -> URL {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.font = NSFont.systemFont(ofSize: 12)
        view.string = text
        let bytes = view.dataWithPDF(inside: view.bounds)
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        XCTAssertTrue(document.string?.contains(text) == true, "Search fixture must contain extractable text")
        let url = temporaryURL()
        try bytes.write(to: url)
        return url
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
    }

    private func fixture(discardDecision: @escaping (String) -> DocumentDiscardDecision,
                         saveDestination: ((String) -> URL?)? = nil) -> Fixture
    {
        fixture(controller: StudioController(discardDecision: discardDecision, saveDestination: saveDestination,
                                              errorPresenter: { _ in }))
    }

    private func fixture(controller: StudioController) -> Fixture {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
        let text = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 20), forType: .widget, withProperties: nil)
        text.widgetFieldType = .text
        text.fieldName = "Native field"
        text.widgetStringValue = "Initial"
        page.addAnnotation(text)
        document.insert(page, at: 0)
        let view = LifecyclePDFView()
        controller.attach(pdfView: view)
        controller.setDocument(document)
        return Fixture(controller: controller, view: view, document: document, page: page, text: text)
    }

    private func addNote(to fixture: Fixture) {
        let note = PDFAnnotation(bounds: CGRect(x: 20, y: 50, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "Unsaved note"
        fixture.page.addAnnotation(note)
        fixture.controller.registerAnnotationAddition(note)
    }

    private struct Fixture {
        let controller: StudioController
        let view: LifecyclePDFView
        let document: PDFDocument
        let page: PDFPage
        let text: PDFAnnotation
    }
}

private final class LifecyclePDFView: PDFView {
    override var currentPage: PDFPage? { document?.page(at: 0) }
    override var visiblePages: [PDFPage] { currentPage.map { [$0] } ?? [] }
}

private final class LifecycleEditingWindow: NSWindow {
    var resignEditor: (() -> Bool)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if responder == nil, let resignEditor { return resignEditor() }
        return super.makeFirstResponder(responder)
    }
}
