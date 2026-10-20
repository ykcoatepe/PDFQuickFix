import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class DocumentTransitionGuardTests: XCTestCase {
    func testCleanDocumentDoesNotAskToSave() throws {
        let state = DocumentChangeState()
        let document = PDFDocument()
        state.adopt(document)
        let token = try XCTUnwrap(state.authorizeTransition(
            decide: { XCTFail("Clean document should not prompt"); return .cancel },
            save: { XCTFail("Clean document should not save"); return .failed }
        ))
        XCTAssertTrue(state.isCurrent(token))
    }

    func testCancelAndUnsuccessfulSaveKeepEditsAndDenyTransition() {
        for outcome in [DocumentSaveOutcome.cancelled, .failed] {
            let state = DocumentChangeState()
            let document = PDFDocument()
            state.adopt(document)
            state.markChanged(in: document)
            XCTAssertNil(state.authorizeTransition(decide: { .save }, save: { outcome }))
            XCTAssertTrue(state.hasUnsavedChanges)
            XCTAssertNil(state.authorizeTransition(
                decide: { .cancel },
                save: { XCTFail("Cancel should not save"); return .saved }
            ))
            XCTAssertTrue(state.hasUnsavedChanges)
        }
    }

    func testDiscardAuthorizationDoesNotClearDirtyAndNewEditInvalidatesIt() throws {
        let state = DocumentChangeState()
        let document = PDFDocument()
        state.adopt(document)
        state.markChanged(in: document)
        let token = try XCTUnwrap(state.authorizeTransition(
            decide: { .discard }, save: { .failed }
        ))
        XCTAssertTrue(state.hasUnsavedChanges, "A failed replacement open must retain the edits.")
        state.markChanged(in: document)
        XCTAssertFalse(state.isCurrent(token), "An edit during a slow open requires a new decision.")
    }

    func testReplacementInvalidatesAuthorizationAndIgnoresOldDocumentChanges() throws {
        let state = DocumentChangeState()
        let old = PDFDocument()
        let new = PDFDocument()
        state.adopt(old)
        let token = try XCTUnwrap(state.authorizeTransition(decide: { .discard }, save: { .failed }))
        state.adopt(new)
        state.markChanged(in: old)
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertFalse(state.isCurrent(token))
        XCTAssertFalse(state.markSaved(old, revision: token))
    }

    func testSaveCanOnlyCheckpointTheSavedRevision() {
        let state = DocumentChangeState()
        let document = PDFDocument()
        state.adopt(document)
        state.markChanged(in: document)
        let savedRevision = state.captureRevision()
        state.markChanged(in: document)
        XCTAssertFalse(state.markSaved(document, revision: savedRevision))
        XCTAssertTrue(state.hasUnsavedChanges)
        XCTAssertTrue(state.markSaved(document, revision: state.captureRevision()))
        XCTAssertFalse(state.hasUnsavedChanges)
    }

    func testSuccessfulSaveMustAlsoCheckpointChangesBeforeTransition() throws {
        let state = DocumentChangeState()
        let document = PDFDocument()
        state.adopt(document)
        state.markChanged(in: document)
        XCTAssertNil(state.authorizeTransition(decide: { .save }, save: { .saved }))
        let token = try XCTUnwrap(state.authorizeTransition(decide: { .save }, save: {
            state.markSaved(document, revision: state.captureRevision())
            return .saved
        }))
        XCTAssertFalse(state.hasUnsavedChanges)
        XCTAssertTrue(state.isCurrent(token))
    }

    func testMutationDuringPromptAndNestedTransitionCannotDiscardNewEdits() {
        let state = DocumentChangeState()
        let document = PDFDocument()
        state.adopt(document)
        state.markChanged(in: document)
        XCTAssertNil(state.authorizeTransition(decide: {
            XCTAssertNil(state.authorizeTransition(decide: { .discard }, save: { .failed }))
            state.markChanged(in: document)
            return .discard
        }, save: { .failed }))
        XCTAssertTrue(state.hasUnsavedChanges)
    }

    func testAdoptingSameDocumentDoesNotEraseItsDirtyState() {
        let state = DocumentChangeState()
        let document = PDFDocument()
        state.adopt(document)
        state.markChanged(in: document)
        state.adopt(document)
        XCTAssertTrue(state.hasUnsavedChanges)
    }

    func testOldSaveCannotClearChangesAfterReAdoptingSameDocument() {
        let state = DocumentChangeState()
        let first = PDFDocument()
        let other = PDFDocument()
        state.adopt(first)
        state.markChanged(in: first)
        let oldSave = state.captureRevision()
        state.adopt(other)
        state.adopt(first)
        state.markChanged(in: first)
        XCTAssertEqual(state.revision, 1, "The numeric revision is reused in the new generation.")
        XCTAssertFalse(state.markSaved(first, revision: oldSave))
        XCTAssertTrue(state.hasUnsavedChanges)
    }
}
