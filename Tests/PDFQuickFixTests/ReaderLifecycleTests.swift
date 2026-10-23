import AppKit
import PDFKit
import XCTest
@testable import PDFQuickFix

@MainActor
final class ReaderLifecycleTests: XCTestCase {
    private final class View: PDFView {
        var displayedPage: PDFPage?
        var editingWindow: NSWindow?
        override var currentPage: PDFPage? { displayedPage ?? super.currentPage }
        override var visiblePages: [PDFPage] { currentPage.map { [$0] } ?? [] }
        override var window: NSWindow? { editingWindow ?? super.window }
    }

    private final class EditingWindow: NSWindow {
        var commit: (() -> Bool)?
        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            commit?() ?? true
        }
    }

    private final class RepresentedView: ReaderPDFView {
        var editingWindow: NSWindow?
        override var window: NSWindow? { editingWindow ?? super.window }
    }

    private func document(pages: Int = 2) -> PDFDocument {
        let result = PDFDocument()
        for index in 0..<pages {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
            result.insert(page, at: index)
        }
        return result
    }

    private func attach(_ document: PDFDocument, to controller: ReaderControllerPro) -> View {
        let view = View(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        controller.document = document
        view.document = document
        view.displayedPage = document.page(at: 0)
        controller.pdfView = view
        return view
    }

    private func waitForOpen(_ controller: ReaderControllerPro) async throws {
        let deadline = Date().addingTimeInterval(5)
        while controller.isLoadingDocument, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(controller.isLoadingDocument)
    }

    func testCancelCloseKeepsEditsAndUndoButDiscardCloses() throws {
        var decision: DocumentDiscardDecision = .cancel
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), discardDecision: { _ in decision })
        let doc = document()
        let view = attach(doc, to: controller)
        controller.rotateCurrentPageRight()
        XCTAssertTrue(controller.hasUnsavedChanges)
        controller.closeDocument()
        XCTAssertTrue(controller.document === doc)
        XCTAssertEqual(doc.page(at: 0)?.rotation, 90)
        controller.undoLastEdit()
        XCTAssertEqual(doc.page(at: 0)?.rotation, 0)
        XCTAssertTrue(controller.hasUnsavedChanges)
        decision = .discard
        controller.closeDocument()
        XCTAssertNil(controller.document)
        XCTAssertFalse(controller.hasUnsavedChanges)
        withExtendedLifetime(view) {}
    }

    func testSaveAsCancellationCannotApproveClose() {
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), discardDecision: { _ in .save }, saveDestination: { _ in nil })
        let doc = document()
        let view = attach(doc, to: controller)
        controller.rotateCurrentPageRight()
        XCTAssertEqual(controller.saveAsOutcome(), .cancelled)
        controller.closeDocument()
        XCTAssertTrue(controller.document === doc)
        XCTAssertTrue(controller.hasUnsavedChanges)
        withExtendedLifetime(view) {}
    }

    func testFailedSaveCannotApproveClose() {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.pdf")
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), discardDecision: { _ in .save },
                                             saveDestination: { _ in destination },
                                             errorPresenter: { _ in })
        let doc = document()
        let view = attach(doc, to: controller)
        controller.rotateCurrentPageRight()
        controller.closeDocument()
        XCTAssertTrue(controller.document === doc)
        XCTAssertTrue(controller.hasUnsavedChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        withExtendedLifetime(view) {}
    }

    func testSuccessfulSaveCheckpointsNativeFieldValue() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), saveDestination: { _ in output })
        let doc = document()
        let field = PDFFormBuilder.makeTextField(name: "Text", rect: CGRect(x: 20, y: 20, width: 100, height: 30))
        field.widgetStringValue = "Before"
        doc.page(at: 0)?.addAnnotation(field)
        let view = attach(doc, to: controller)
        field.widgetStringValue = "After"
        // No yield: save must flush before the queued KVO task can run.
        XCTAssertEqual(controller.saveAsOutcome(), .saved)
        XCTAssertFalse(controller.hasUnsavedChanges)
        let reloaded = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(reloaded.page(at: 0)?.annotations.first?.widgetStringValue, "After")
        withExtendedLifetime(view) {}
    }

    func testNativeFieldFlushTriggersClosePromptBeforeKVO() {
        var prompts = 0
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), discardDecision: { _ in prompts += 1; return .cancel })
        let doc = document()
        let field = PDFFormBuilder.makeTextField(name: "Text", rect: .zero)
        doc.page(at: 0)?.addAnnotation(field)
        let view = attach(doc, to: controller)
        field.widgetStringValue = "Changed"
        controller.closeDocument()
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(controller.document === doc)
        XCTAssertTrue(controller.hasUnsavedChanges)
        withExtendedLifetime(view) {}
    }

    func testSavePanelReentrantEditCancelsBeforeDestinationWrite() {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        var controller: ReaderControllerPro!
        controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), saveDestination: { _ in
            controller.rotateCurrentPageRight()
            return output
        })
        let doc = document()
        let view = attach(doc, to: controller)
        XCTAssertEqual(controller.saveAsOutcome(), .failed)
        XCTAssertTrue(controller.hasUnsavedChanges)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        withExtendedLifetime(view) {}
    }

    func testFailedReplacementKeepsOriginalURLChangesAndUndo() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertTrue(document().write(to: source))
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), repairSourceURL: { $0 }, discardDecision: { _ in .discard }, errorPresenter: { _ in })
        let view = View(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        controller.pdfView = view
        controller.open(url: source)
        try await waitForOpen(controller)
        let original = try XCTUnwrap(controller.document)
        view.displayedPage = original.page(at: 0)
        controller.rotateCurrentPageRight()
        controller.open(url: source.appendingPathExtension("missing"))
        try await waitForOpen(controller)
        XCTAssertTrue(controller.document === original)
        XCTAssertEqual(controller.sourceURL, source)
        XCTAssertTrue(controller.hasUnsavedChanges)
        controller.undoLastEdit()
        XCTAssertEqual(original.page(at: 0)?.rotation, 0)
    }

    func testCancelledPasswordOpenKeepsOriginalChanges() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertTrue(document().write(to: source, withOptions: [.userPasswordOption: "user", .ownerPasswordOption: "owner"]))
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), passwordProvider: { _ in nil }, discardDecision: { _ in .discard })
        let original = document()
        let view = attach(original, to: controller)
        controller.rotateCurrentPageRight()
        controller.open(url: source)
        try await waitForOpen(controller)
        XCTAssertTrue(controller.document === original)
        XCTAssertTrue(controller.hasUnsavedChanges)
        XCTAssertEqual(original.page(at: 0)?.rotation, 90)
        withExtendedLifetime(view) {}
    }

    func testEditAfterOpenAuthorizationRejectsCandidate() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertTrue(document().write(to: source))
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), repairSourceURL: { $0 }, discardDecision: { _ in .discard })
        let original = document()
        let view = attach(original, to: controller)
        controller.open(url: source)
        controller.rotateCurrentPageRight()
        try await waitForOpen(controller)
        XCTAssertTrue(controller.document === original)
        XCTAssertTrue(controller.hasUnsavedChanges)
        XCTAssertNil(controller.sourceURL)
        withExtendedLifetime(view) {}
    }

    func testPendingNativeFieldAtCandidateAdoptionKeepsOriginal() async throws {
        try await assertPendingNativeEditingPreventsAdoption(refusesCommit: false)
    }

    func testNativeEditorRefusingCommitPreventsCandidateAdoption() async throws {
        try await assertPendingNativeEditingPreventsAdoption(refusesCommit: true)
    }

    private func assertPendingNativeEditingPreventsAdoption(refusesCommit: Bool) async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertTrue(document().write(to: source))
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil), repairSourceURL: { $0 }, discardDecision: { _ in .discard })
        let original = document()
        let field = PDFFormBuilder.makeTextField(name: "Pending", rect: CGRect(x: 10, y: 10, width: 100, height: 30))
        field.widgetStringValue = "Before"
        original.page(at: 0)?.addAnnotation(field)
        let view = attach(original, to: controller)
        let window = EditingWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        view.editingWindow = window
        controller.open(url: source)
        // The candidate callback runs on the main actor after this synchronous
        // setup. Until resignation, only the native editor owns the new text.
        var commits = 0
        window.commit = {
            commits += 1
            if refusesCommit { return false }
            field.widgetStringValue = "Pending editor value"
            return true
        }
        try await waitForOpen(controller)
        XCTAssertGreaterThan(commits, 0)
        XCTAssertTrue(controller.document === original)
        XCTAssertNil(controller.sourceURL)
        if !refusesCommit {
            XCTAssertEqual(field.widgetStringValue, "Pending editor value")
            XCTAssertTrue(controller.hasUnsavedChanges)
        }
        withExtendedLifetime(view) {}
    }

    func testPageNotificationsTrackCurrentViewAndIgnoreOldView() {
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil))
        let doc = document()
        let oldView = attach(doc, to: controller)
        oldView.displayedPage = doc.page(at: 1)
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: oldView)
        XCTAssertEqual(controller.currentPageIndex, 1)
        let newView = View()
        newView.document = doc
        newView.displayedPage = doc.page(at: 0)
        controller.pdfView = newView
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: oldView)
        XCTAssertEqual(controller.currentPageIndex, 0)
        XCTAssertFalse(controller.hasUnsavedChanges)
    }

    func testViewTeardownRetainsLinksWhenNativeEditorRefusesCommit() {
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil))
        let view = RepresentedView()
        let window = EditingWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        view.editingWindow = window
        view.controller = controller
        controller.document = document()
        view.document = controller.document
        controller.pdfView = view
        window.commit = { false }

        PDFViewProRepresented.dismantleNSView(view, coordinator: ())
        XCTAssertTrue(controller.pdfView === view)
        XCTAssertTrue(view.controller === controller)

        window.commit = { true }
        PDFViewProRepresented.dismantleNSView(view, coordinator: ())
        XCTAssertNil(controller.pdfView)
        XCTAssertNil(view.controller)
    }

    func testQueuedSearchMatchCannotReappearAfterClearOrReplacement() async {
        let controller = ReaderControllerPro(recentFiles: RecentFilesManager(defaults: nil))
        let doc = document()
        controller.document = doc
        let selection = PDFSelection(document: doc)
        controller.find("nonexistent")
        NotificationCenter.default.post(name: .PDFDocumentDidFindMatch, object: doc,
                                        userInfo: ["PDFDocumentFoundSelection": selection])
        controller.find("")
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(controller.searchMatches.isEmpty)
        controller.find("nonexistent")
        NotificationCenter.default.post(name: .PDFDocumentDidFindMatch, object: doc,
                                        userInfo: ["PDFDocumentFoundSelection": selection])
        controller.document = document()
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(controller.searchMatches.isEmpty)
        XCTAssertNil(controller.currentMatchIndex)
        XCTAssertFalse(controller.hasUnsavedChanges)
    }
}
