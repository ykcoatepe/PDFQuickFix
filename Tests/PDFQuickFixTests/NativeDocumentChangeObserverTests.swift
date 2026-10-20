import AppKit
import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class NativeDocumentChangeObserverTests: XCTestCase {
    func testAttachRequiresExactViewDocumentAndReadingDoesNotChangeIt() async {
        let fixture = fixture()
        let observer = NativeDocumentChangeObserver()
        var changes = 0
        fixture.view.document = PDFDocument()
        XCTAssertFalse(observer.attach(document: fixture.document, view: fixture.view) { _ in changes += 1 })
        fixture.text.widgetStringValue = "Unobserved"
        XCTAssertFalse(observer.flush())

        fixture.view.document = fixture.document
        XCTAssertTrue(observer.attach(document: fixture.document, view: fixture.view) { _ in changes += 1 })
        fixture.text.widgetStringValue = "Unobserved" // Same model value is not an edit.
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: fixture.view)
        NotificationCenter.default.post(name: .PDFDocumentDidFindMatch, object: fixture.document)
        XCTAssertFalse(observer.flush())
        await drainCallbacks()
        XCTAssertEqual(changes, 0)
    }

    func testNativeValueAndNoteContentsKVODetectActualChanges() async {
        let fixture = fixture()
        let observer = NativeDocumentChangeObserver()
        var changedDocuments: [PDFDocument] = []
        observer.attach(document: fixture.document, view: fixture.view) { changedDocuments.append($0) }

        fixture.text.widgetStringValue = "Edited text"
        await drainCallbacks()
        XCTAssertEqual(changedDocuments.count, 1)

        fixture.checkbox.buttonWidgetState = .onState
        await drainCallbacks()
        XCTAssertEqual(changedDocuments.count, 2)

        // Code-level coverage; editing a native note popup still needs separate UI proof.
        fixture.note.contents = "Edited note"
        await drainCallbacks()
        XCTAssertEqual(changedDocuments.count, 3)
        XCTAssertTrue(changedDocuments.allSatisfy { $0 === fixture.document })
        XCTAssertFalse(observer.flush())
    }

    func testFlushDetectsQueuedKVOAndLateCallbacksDoNotRedirtyAfterSave() async {
        let fixture = fixture()
        let observer = NativeDocumentChangeObserver()
        var dirty = false
        var changes = 0
        observer.attach(document: fixture.document, view: fixture.view) { _ in
            dirty = true
            changes += 1
        }

        fixture.text.widgetStringValue = "Queued native edit"
        XCTAssertTrue(observer.flush(), "A synchronous save boundary must not wait for KVO tasks.")
        XCTAssertTrue(dirty)
        XCTAssertEqual(changes, 1)
        dirty = false // Represents a successful save checkpoint after the flush.

        await drainCallbacks()
        XCTAssertFalse(dirty)
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(observer.flush())
    }

    func testRepeatedAttachDoesNotRebaselineAnUnflushedEdit() {
        let fixture = fixture()
        let observer = NativeDocumentChangeObserver()
        var changes = 0
        observer.attach(document: fixture.document, view: fixture.view) { _ in XCTFail("Superseded callback") }
        fixture.text.widgetStringValue = "Pending edit"

        observer.attach(document: fixture.document, view: fixture.view) { _ in changes += 1 }

        XCTAssertTrue(observer.flush())
        XCTAssertEqual(changes, 1)
    }

    func testOldDocumentCallbacksCannotChangeReplacement() async {
        let old = fixture()
        let replacement = fixture()
        let observer = NativeDocumentChangeObserver()
        var oldChanges = 0
        var replacementChanges = 0
        observer.attach(document: old.document, view: old.view) { _ in oldChanges += 1 }
        old.text.widgetStringValue = "Queued before replacement"

        observer.attach(document: replacement.document, view: replacement.view) { _ in replacementChanges += 1 }
        old.checkbox.buttonWidgetState = .onState
        await drainCallbacks()
        XCTAssertEqual(oldChanges, 0)
        XCTAssertEqual(replacementChanges, 0)

        replacement.text.widgetStringValue = "Replacement edit"
        XCTAssertTrue(observer.flush())
        XCTAssertEqual(replacementChanges, 1)
    }

    func testChangingViewDocumentAndDetachingIgnoreOldEdits() async {
        let fixture = fixture()
        let observer = NativeDocumentChangeObserver()
        var changes = 0
        observer.attach(document: fixture.document, view: fixture.view) { _ in changes += 1 }
        fixture.text.widgetStringValue = "Queued old edit"
        fixture.view.document = PDFDocument()
        NotificationCenter.default.post(name: .PDFViewDocumentChanged, object: fixture.view)
        XCTAssertFalse(observer.flush())
        await drainCallbacks()
        XCTAssertEqual(changes, 0)

        fixture.view.document = fixture.document
        observer.attach(document: fixture.document, view: fixture.view) { _ in changes += 1 }
        observer.detach()
        fixture.note.contents = "Detached edit"
        await drainCallbacks()
        XCTAssertFalse(observer.flush())
        XCTAssertEqual(changes, 0)
    }

    func testFlushBeforeViewTeardownPreservesEditsAndReattachmentObservesSameDocument() async {
        let fixture = fixture()
        let observer = NativeDocumentChangeObserver()
        var changes = 0
        observer.attach(document: fixture.document, view: fixture.view) { _ in changes += 1 }
        fixture.text.widgetStringValue = "Edit before switching views"
        XCTAssertTrue(observer.flush())
        observer.detach()

        let newView = VisiblePagesPDFView()
        newView.document = fixture.document
        newView.reportedCurrentPage = fixture.page
        newView.reportedVisiblePages = [fixture.page]
        observer.attach(document: fixture.document, view: newView) { _ in changes += 1 }
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: fixture.view)
        await drainCallbacks()
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(observer.flush())

        fixture.checkbox.buttonWidgetState = .onState
        XCTAssertTrue(observer.flush())
        XCTAssertEqual(changes, 2)
    }

    func testPageNotificationObservesNewPageSynchronouslyAndRetainsVisitedPage() {
        let first = fixture()
        let second = CountingPage()
        let untouched = CountingPage()
        let nextField = textField()
        second.addAnnotation(nextField)
        first.document.insert(second, at: 1)
        first.document.insert(untouched, at: 2)
        second.annotationReads = 0
        untouched.annotationReads = 0
        let observer = NativeDocumentChangeObserver()
        var changes = 0
        observer.attach(document: first.document, view: first.view) { _ in changes += 1 }
        XCTAssertEqual(second.annotationReads, 0)
        XCTAssertEqual(untouched.annotationReads, 0)

        first.view.reportedCurrentPage = second
        first.view.reportedVisiblePages = [second]
        NotificationCenter.default.post(name: .PDFViewPageChanged, object: first.view)
        nextField.widgetStringValue = "Edit immediately after page navigation"
        XCTAssertTrue(observer.flush())
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(untouched.annotationReads, 0, "Opening/navigating must not scan every page.")

        first.text.widgetStringValue = "Previously visited page edit"
        XCTAssertTrue(observer.flush())
        XCTAssertEqual(changes, 2)
    }

    func testRefreshBaselinesAppAddedAnnotationAndDropsRemovedAnnotations() async {
        let fixture = fixture()
        let observer = NativeDocumentChangeObserver()
        var changes = 0
        observer.attach(document: fixture.document, view: fixture.view) { _ in changes += 1 }
        let added = PDFAnnotation(bounds: .zero, forType: .text, withProperties: nil)
        added.contents = "App-owned addition"
        fixture.page.addAnnotation(added)
        observer.refresh() // The app explicitly marks its addition dirty itself.
        XCTAssertFalse(observer.flush())

        added.contents = "Subsequent native edit"
        XCTAssertTrue(observer.flush())
        XCTAssertEqual(changes, 1)
        fixture.page.removeAnnotation(added)
        observer.refresh()
        added.contents = "Removed annotation cannot dirty the document"
        await drainCallbacks()
        XCTAssertFalse(observer.flush())
        XCTAssertEqual(changes, 1)
    }

    private func drainCallbacks() async {
        await Task.yield()
        await Task.yield()
    }

    private func textField() -> PDFAnnotation {
        let field = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 80, height: 20), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.widgetStringValue = "Initial text"
        return field
    }

    private func fixture() -> Fixture {
        let document = PDFDocument()
        let page = CountingPage()
        let text = textField()
        let checkbox = PDFAnnotation(bounds: CGRect(x: 10, y: 40, width: 20, height: 20), forType: .widget, withProperties: nil)
        checkbox.widgetFieldType = .button
        checkbox.widgetControlType = .checkBoxControl
        checkbox.buttonWidgetState = .offState
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 70, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Initial note"
        [text, checkbox, note].forEach { page.addAnnotation($0) }
        document.insert(page, at: 0)
        let view = VisiblePagesPDFView()
        view.document = document
        view.reportedCurrentPage = page
        view.reportedVisiblePages = [page]
        return Fixture(document: document, page: page, view: view, text: text, checkbox: checkbox, note: note)
    }

    private struct Fixture {
        let document: PDFDocument
        let page: CountingPage
        let view: VisiblePagesPDFView
        let text: PDFAnnotation
        let checkbox: PDFAnnotation
        let note: PDFAnnotation
    }
}

private final class CountingPage: PDFPage {
    var annotationReads = 0
    override var annotations: [PDFAnnotation] {
        annotationReads += 1
        return super.annotations
    }
}

private final class VisiblePagesPDFView: PDFView {
    private var reportedDocument: PDFDocument?
    var reportedCurrentPage: PDFPage?
    var reportedVisiblePages: [PDFPage] = []

    override var document: PDFDocument? {
        get { reportedDocument }
        set { reportedDocument = newValue }
    }
    override var currentPage: PDFPage? { reportedCurrentPage }
    override var visiblePages: [PDFPage] { reportedVisiblePages }
}
