import AppKit
import SwiftUI

/// A close decision is provisional until every participating document has
/// answered. A later modal prompt may allow an earlier document to change.
@MainActor
struct DocumentCloseAuthorization {
    let isCurrent: () -> Bool
}

@MainActor
enum DocumentCloseTransaction {
    static func authorize(
        _ participants: [() -> DocumentCloseAuthorization?]
    ) -> DocumentCloseAuthorization? {
        var approvals: [DocumentCloseAuthorization] = []
        for prepare in participants {
            guard let approval = prepare() else { return nil }
            approvals.append(approval)
        }
        let result = DocumentCloseAuthorization {
            approvals.allSatisfy { $0.isCurrent() }
        }
        return result.isCurrent() ? result : nil
    }
}

/// WindowGroup creates separate controller pairs. Quit must include all windows,
/// including documents in the inactive Reader/Studio workbench.
@MainActor
final class DocumentCloseRegistry {
    static let shared = DocumentCloseRegistry()

    private struct Entry {
        weak var owner: AnyObject?
        let prepare: () -> DocumentCloseAuthorization?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var membershipRevision: UInt64 = 0
    private var isResolving = false

    func register(_ owner: AnyObject, prepare: @escaping () -> DocumentCloseAuthorization?) {
        let key = ObjectIdentifier(owner)
        if entries[key] == nil { membershipRevision &+= 1 }
        entries[key] = Entry(owner: owner, prepare: prepare)
    }

    func unregister(_ owner: AnyObject) {
        if entries.removeValue(forKey: ObjectIdentifier(owner)) != nil {
            membershipRevision &+= 1
        }
    }

    func authorizeTermination() -> Bool {
        guard !isResolving else { return false }
        isResolving = true
        defer { isResolving = false }
        entries = entries.filter { $0.value.owner != nil }
        let revision = membershipRevision
        let participants = entries.values.map(\.prepare)
        guard let approval = DocumentCloseTransaction.authorize(participants) else { return false }
        // Opening/closing a window during a save panel invalidates this attempt.
        return membershipRevision == revision && approval.isCurrent()
    }
}

/// Preserve SwiftUI's existing delegate for every event except the close gate.
/// The representable's coordinator owns this proxy for the window's lifetime.
struct DocumentWindowCloseGuard: NSViewRepresentable {
    let isDocumentEdited: Bool
    let prepare: @MainActor () -> DocumentCloseAuthorization?

    func makeCoordinator() -> Coordinator { Coordinator(prepare: prepare) }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        context.coordinator.prepare = prepare
        context.coordinator.isDocumentEdited = isDocumentEdited
        context.coordinator.attach(to: view.window)
    }

    static func dismantleNSView(_ view: HostView, coordinator: Coordinator) {
        coordinator.detach()
        view.coordinator = nil
    }

    final class HostView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var prepare: @MainActor () -> DocumentCloseAuthorization?
        var isDocumentEdited = false {
            didSet { window?.isDocumentEdited = isDocumentEdited }
        }
        private weak var window: NSWindow?
        private weak var originalDelegate: (any NSWindowDelegate)?

        init(prepare: @escaping @MainActor () -> DocumentCloseAuthorization?) {
            self.prepare = prepare
        }

        func attach(to newWindow: NSWindow?) {
            guard let newWindow else { return }
            if window !== newWindow {
                detach()
                window = newWindow
            }
            if newWindow.delegate !== self {
                originalDelegate = newWindow.delegate
                newWindow.delegate = self
            }
            newWindow.isDocumentEdited = isDocumentEdited
            DocumentCloseRegistry.shared.register(self) { [weak self] in
                self?.prepare()
            }
        }

        func detach() {
            DocumentCloseRegistry.shared.unregister(self)
            if window?.delegate === self { window?.delegate = originalDelegate }
            window = nil
            originalDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard originalDelegate?.windowShouldClose?(sender) ?? true else { return false }
            guard let authorization = prepare() else { return false }
            return authorization.isCurrent()
        }

        func windowWillClose(_ notification: Notification) {
            DocumentCloseRegistry.shared.unregister(self)
            originalDelegate?.windowWillClose?(notification)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (originalDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if originalDelegate?.responds(to: selector) == true { return originalDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}
