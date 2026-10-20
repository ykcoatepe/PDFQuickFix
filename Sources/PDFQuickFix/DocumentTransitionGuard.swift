import AppKit
import Combine
import PDFKit

enum DocumentSaveOutcome: Equatable {
    case saved
    case cancelled
    case failed
}

enum DocumentDiscardDecision {
    case save
    case discard
    case cancel
}

/// An approval belongs to one document revision. An asynchronous open must
/// recheck it immediately before replacing the current document.
struct DocumentRevision: Equatable {
    fileprivate let generation: UUID
    fileprivate let revision: UInt64
}

@MainActor
final class DocumentChangeState: ObservableObject {
    @Published private(set) var hasUnsavedChanges = false
    private(set) var revision: UInt64 = 0
    private var document: PDFDocument?
    private var generation = UUID()
    private var isResolvingTransition = false

    func adopt(_ newDocument: PDFDocument?) {
        guard document !== newDocument else { return }
        document = newDocument
        generation = UUID()
        revision = 0
        hasUnsavedChanges = false
    }

    /// Identity checking prevents queued notifications from a previous document
    /// from changing the state of its replacement.
    func markChanged(in editedDocument: PDFDocument) {
        guard document === editedDocument else { return }
        revision &+= 1
        hasUnsavedChanges = true
    }

    /// A successful write only checkpoints the revision it actually saved.
    @discardableResult
    func markSaved(_ savedDocument: PDFDocument, revision savedRevision: DocumentRevision) -> Bool {
        guard document === savedDocument, isCurrent(savedRevision) else { return false }
        hasUnsavedChanges = false
        return true
    }

    func isCurrent(_ authorization: DocumentRevision) -> Bool {
        authorization.generation == generation && authorization.revision == revision
    }

    func authorizeTransition(
        decide: () -> DocumentDiscardDecision,
        save: () -> DocumentSaveOutcome
    ) -> DocumentRevision? {
        guard !isResolvingTransition else { return nil }
        isResolvingTransition = true
        defer { isResolvingTransition = false }
        let initial = captureRevision()
        guard hasUnsavedChanges else { return initial }

        let decision = decide()
        // Modal UI can process asynchronous events. An answer about the old
        // revision must not approve changes arriving while the prompt was open.
        guard isCurrent(initial) else { return nil }
        switch decision {
        case .cancel:
            return nil
        case .discard:
            // Keep edits and dirty state until a replacement actually commits.
            return initial
        case .save:
            guard save() == .saved, !hasUnsavedChanges else { return nil }
            return captureRevision()
        }
    }

    func captureRevision() -> DocumentRevision {
        DocumentRevision(generation: generation, revision: revision)
    }
}

@MainActor
enum DocumentDiscardPrompt {
    static func decide(documentName: String) -> DocumentDiscardDecision {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(documentName)”?"
        alert.informativeText = "Your changes will be lost if you continue without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
