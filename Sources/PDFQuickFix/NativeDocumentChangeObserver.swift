import AppKit
@preconcurrency import PDFKit

/// Tracks native PDFKit value edits on visible and previously visited pages.
/// App-mediated structural edits must mark the document changed themselves, then refresh.
@MainActor
final class NativeDocumentChangeObserver {
    private struct Snapshot: Equatable {
        let widgetValue: String?
        let buttonState: Int?
        let contents: String?

        init(_ annotation: PDFAnnotation) {
            let isWidget = annotation.type == "Widget"
            widgetValue = isWidget ? annotation.widgetStringValue : nil
            buttonState = isWidget && annotation.widgetFieldType == .button
                ? annotation.buttonWidgetState.rawValue : nil
            contents = annotation.contents
        }
    }

    @MainActor
    private final class TrackedAnnotation {
        let annotation: PDFAnnotation
        var snapshot: Snapshot
        var observations: [NSKeyValueObservation] = []

        init(_ annotation: PDFAnnotation) {
            self.annotation = annotation
            snapshot = Snapshot(annotation)
        }
    }

    private weak var document: PDFDocument?
    private weak var view: PDFView?
    private var generation = UUID()
    private var onChange: ((PDFDocument) -> Void)?
    private var annotations: [ObjectIdentifier: TrackedAnnotation] = [:]
    private var notifications: [NSObjectProtocol] = []

    deinit {
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// A mismatched or not-yet-associated view cannot observe the document.
    /// Reattaching the same pair preserves snapshots, including unflushed edits.
    @discardableResult
    func attach(document: PDFDocument, view: PDFView,
                onChange: @escaping (PDFDocument) -> Void) -> Bool
    {
        if self.document === document, self.view === view, view.document === document {
            self.onChange = onChange
            refresh()
            return true
        }
        detach()
        guard view.document === document else { return false }
        self.document = document
        self.view = view
        self.onChange = onChange
        let attachment = generation
        let names: [Notification.Name] = [
            .PDFViewPageChanged, .PDFViewVisiblePagesChanged,
            .PDFViewAnnotationWillHit, .PDFViewAnnotationHit, .PDFViewDocumentChanged,
        ]
        for name in names {
            notifications.append(NotificationCenter.default.addObserver(
                forName: name, object: view, queue: .main
            ) { [weak self] _ in
                // AnnotationWillHit must establish a baseline before native editing begins.
                MainActor.assumeIsolated {
                    guard let self, self.generation == attachment else { return }
                    self.refresh()
                }
            })
        }
        refresh()
        return true
    }

    /// Discovers annotations only on the view's current/visible pages. Previously
    /// visited annotations retain their observations even after scrolling away.
    func refresh() {
        guard let document, let view, view.document === document else {
            detach()
            return
        }
        for id in Array(annotations.keys) {
            if annotations[id]?.annotation.page?.document !== document {
                annotations.removeValue(forKey: id)
            }
        }
        var pages = view.visiblePages
        if let page = view.currentPage { pages.append(page) }
        var seenPages: Set<ObjectIdentifier> = []
        for page in pages where page.document === document {
            guard seenPages.insert(ObjectIdentifier(page)).inserted else { continue }
            for annotation in page.annotations {
                let id = ObjectIdentifier(annotation)
                guard annotations[id] == nil else { continue }
                let tracked = TrackedAnnotation(annotation)
                annotations[id] = tracked
                observe(tracked, generation: generation)
            }
        }
    }

    /// Call synchronously before capturing a save/transition revision, and before
    /// tearing down a view. Updating snapshots first makes queued KVO callbacks no-ops.
    @discardableResult
    func flush() -> Bool {
        refresh()
        guard let document, view?.document === document else { return false }
        var changed = false
        for tracked in annotations.values where tracked.annotation.page?.document === document {
            let current = Snapshot(tracked.annotation)
            if current != tracked.snapshot {
                tracked.snapshot = current
                changed = true
            }
        }
        if changed { onChange?(document) }
        return changed
    }

    /// Does not flush implicitly: callers flush while the old document/view is
    /// still associated, before adopting a replacement or destroying the view.
    func detach() {
        generation = UUID()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications = []
        annotations = [:]
        onChange = nil
        document = nil
        view = nil
    }

    private func observe(_ tracked: TrackedAnnotation, generation attachment: UUID) {
        if tracked.annotation.type == "Widget" {
            tracked.observations.append(tracked.annotation.observe(\.widgetStringValue) { [weak self, weak tracked] _, _ in
                Task { @MainActor [weak self, weak tracked] in
                    if let tracked { self?.sample(tracked, generation: attachment) }
                }
            })
            tracked.observations.append(tracked.annotation.observe(\.buttonWidgetState) { [weak self, weak tracked] _, _ in
                Task { @MainActor [weak self, weak tracked] in
                    if let tracked { self?.sample(tracked, generation: attachment) }
                }
            })
        }
        tracked.observations.append(tracked.annotation.observe(\.contents) { [weak self, weak tracked] _, _ in
            Task { @MainActor [weak self, weak tracked] in
                if let tracked { self?.sample(tracked, generation: attachment) }
            }
        })
    }

    private func sample(_ tracked: TrackedAnnotation, generation attachment: UUID) {
        guard generation == attachment, let document, view?.document === document,
              annotations[ObjectIdentifier(tracked.annotation)] === tracked,
              tracked.annotation.page?.document === document else { return }
        let current = Snapshot(tracked.annotation)
        guard current != tracked.snapshot else { return }
        tracked.snapshot = current
        onChange?(document)
    }
}
