import AppKit
import Foundation
import os.log
@preconcurrency import PDFKit
@preconcurrency import PDFQuickFixKit
import SwiftUI
import UniformTypeIdentifiers

struct PageSnapshot: Identifiable, Hashable {
    let id: Int
    let index: Int
    let thumbnail: CGImage?
    let label: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PageSnapshot, rhs: PageSnapshot) -> Bool {
        lhs.id == rhs.id
    }
}

struct OutlineRow: Identifiable, Hashable {
    let outline: PDFOutline
    let depth: Int

    var id: ObjectIdentifier {
        ObjectIdentifier(outline)
    }
}

struct AnnotationRow: Identifiable, Hashable {
    let annotation: PDFAnnotation
    let pageIndex: Int

    var id: ObjectIdentifier {
        ObjectIdentifier(annotation)
    }

    var title: String {
        annotation.fieldName ?? annotation.userName ?? annotation.type ?? "Annotation"
    }
}

struct AnnotationEditDraft {
    var contents: String
    var urlString: String?
}

enum FormFieldKind: String, CaseIterable, Identifiable {
    case text = "Text Field"
    case checkbox = "Checkbox"
    case radio = "Radio"
    case dropdown = "Dropdown"
    case list = "List"
    case signature = "Signature"

    var id: String {
        rawValue
    }

    var usesOptions: Bool {
        self == .dropdown || self == .list
    }
}

struct StudioDebugInfo {
    let pageCount: Int
    let isLargeDocument: Bool
    let isMassiveDocument: Bool
    let renderQueueOps: Int
    let renderTrackedOps: Int
}

struct DocumentMetadataDraft: Equatable {
    var title: String = ""
    var author: String = ""
    var subject: String = ""
    var keywords: String = ""
    var creator: String = ""
    var producer: String = ""
}

@MainActor
final class StudioController: NSObject, ObservableObject, PDFViewDelegate, PDFActionable, StudioToolSwitchable {
    @Published var document: PDFDocument?
    @Published var currentURL: URL?
    @Published var sourceURL: URL?
    private var activeSecurityScope: SecurityScopedAccess?
    @Published var pageSnapshots: [PageSnapshot] = []

    /// Virtualized page provider for massive documents (7000+ pages)
    lazy var virtualPageProvider: VirtualPageProvider = .init(thumbnailCache: self.thumbnailCache)

    @Published var selectedPageIDs: Set<Int> = []
    @Published var outlineRows: [OutlineRow] = []
    @Published var isOutlineTruncated: Bool = false
    @Published var annotationRows: [AnnotationRow] = []
    var formFieldRows: [AnnotationRow] {
        annotationRows.filter { Self.isFormFieldAnnotation($0.annotation) }
    }
    @Published var searchQuery: String = ""
    @Published var searchMatches: [PDFSelection] = []
    @Published var currentMatchIndex: Int?

    @Published var logMessages: [String] = []
    @Published var validationStatus: String?
    @Published var isFullValidationRunning: Bool = false
    @Published var isThumbnailsLoading: Bool = false
    @Published var isDocumentLoading: Bool = false
    @Published var loadingStatus: String?
    @Published var isLargeDocument: Bool = false
    @Published var isMassiveDocument: Bool = false
    @Published var skippedQuickValidation: Bool = false
    private var requiresUnlockedValidation: Bool = false
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var selectedTool: StudioTool = .organize
    @Published var isRepaired: Bool = false
    @Published var isDocumentHealthPresented: Bool = false
    @Published private(set) var currentSelectionText: String?
    private let passwordProvider: PDFPasswordProvider

    init(passwordProvider: @escaping PDFPasswordProvider = PDFPasswordPrompt.requestPassword) {
        self.passwordProvider = passwordProvider
        super.init()
    }

    static func isFormFieldAnnotation(_ annotation: PDFAnnotation) -> Bool {
        switch annotation.widgetFieldType {
        case .text, .button, .choice, .signature:
            true
        default:
            false
        }
    }

    // MARK: - PDFActionable

    func zoomIn() {
        guard let view = pdfView else { return }
        view.zoomIn(self)
    }

    func zoomOut() {
        guard let view = pdfView else { return }
        view.zoomOut(self)
    }

    func rotateLeft() {
        rotateCurrentPageLeft()
    }

    func rotateRight() {
        rotateCurrentPageRight()
    }

    var canReplaceSelectedText: Bool {
        currentSelectionText != nil
    }

    weak var pdfView: PDFView?
    private let validationRunner = DocumentValidationRunner()
    private var snapshotGenerationID = UUID()
    private var snapshotOperation: PageSnapshotRenderOperation?
    private let renderService = PDFRenderService.shared
    private let renderThrottle = RenderThrottle()
    private let snapshotUpdateThrottle = AsyncThrottle(.milliseconds(80))
    private let editUndoManager = UndoManager()
    private var findObserver: NSObjectProtocol?
    private var searchDebounceWorkItem: DispatchWorkItem?
    private let thumbnailCache: NSCache<NSNumber, CGImage> = {
        let cache = NSCache<NSNumber, CGImage>()
        cache.countLimit = 200
        return cache
    }()

    private let thumbnailQueue = DispatchQueue(label: "com.pdfquickfix.thumbnails", qos: .userInitiated)
    private var inflightThumbnails: Set<Int> = []
    private let inflightLock = NSLock()
    private var selectionHelperAnnotation: PDFAnnotation?
    private let snapshotQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private let snapshotTargetSize = CGSize(width: 140, height: 180)
    private let massiveThumbnailTargetSize = CGSize(width: 120, height: 150)
    private let largeDocumentPageThreshold = DocumentValidationRunner.largeDocumentPageThreshold
    private enum ValidationMode { case idle, quick, full }
    private var validationMode: ValidationMode = .idle
    private var studioOpenSignpost: OSSignpostID?
    #if DEBUG
        private var studioOpenStart: Date?
    #endif
    private var deferOutlineLoad = false
    private var deferAnnotationScan = false

    /// Streaming loader for efficient massive document handling
    private let streamingLoader = StreamingPDFLoader()

    deinit {
        if let findObserver {
            NotificationCenter.default.removeObserver(findObserver)
        }
        NotificationCenter.default.removeObserver(self)
        validationRunner.cancelAll()
        snapshotOperation?.cancel()
    }

    func attach(pdfView: PDFView) {
        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: self.pdfView)
        NotificationCenter.default.removeObserver(self, name: .PDFViewSelectionChanged, object: self.pdfView)
        self.pdfView = pdfView
        pdfView.delegate = self
        pdfView.document = document
        applyPDFViewConfiguration()

        NotificationCenter.default.addObserver(self, selector: #selector(handlePageChange(_:)), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(handleSelectionChange(_:)), name: .PDFViewSelectionChanged, object: pdfView)
        refreshSelectionState()

        if let doc = document,
           let page = pdfView.currentPage
        {
            let index = doc.index(for: page)
            prefetchThumbnails(around: index, window: 2, farWindow: 6)
        }
    }

    @objc private func handlePageChange(_ notification: Notification) {
        let sp = PerfLog.begin("StudioPageChanged")
        defer { PerfLog.end("StudioPageChanged", sp) }
        guard let pdfView = notification.object as? PDFView,
              let page = pdfView.currentPage,
              let doc = document else { return }
        let index = doc.index(for: page)

        // Update virtual provider center for massive docs
        if virtualPageProvider.isVirtualized {
            virtualPageProvider.updateCenter(index)
            pageSnapshots = virtualPageProvider.visibleSnapshots
        }

        // For massive documents, cancel outdated thumbnail requests and reprioritize
        if isMassiveDocument {
            renderService.cancelRequestsOutsideWindow(center: index, window: 50)
            renderService.reprioritizeRequests(center: index)
        }

        prefetchThumbnails(around: index, window: 2, farWindow: 6)
    }

    @objc private func handleSelectionChange(_: Notification) {
        refreshSelectionState()
    }

    private func refreshSelectionState() {
        currentSelectionText = normalizedSelectionText(from: pdfView?.currentSelection)
    }

    private func normalizedSelectionText(from selection: PDFSelection?) -> String? {
        guard let value = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    func open(url: URL, access: SecurityScopedAccess? = nil) {
        validationRunner.cancelValidation()
        validationRunner.cancelOpen()
        let effectiveAccess = access ?? SecurityScopedAccess(url: url)
        isDocumentLoading = true
        loadingStatus = "Opening \(url.lastPathComponent)…"
        studioOpenSignpost = PerfLog.begin("StudioOpen")
        #if DEBUG
            PerfMetrics.shared.reset()
            studioOpenStart = Date()
        #endif

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            if let encryptedDoc = PDFDocument(url: url), encryptedDoc.isEncrypted, encryptedDoc.isLocked {
                DispatchQueue.main.async {
                    self.finishEncryptedOpen(document: encryptedDoc,
                                             sourceURL: url,
                                             workingURL: url,
                                             access: effectiveAccess,
                                             isRepaired: false)
                }
                return
            }

            // Repair/Normalize
            var finalURL = url
            var repaired = false
            do {
                let repairedURL = try PDFRepairService().repairIfNeeded(inputURL: url)
                if repairedURL != url {
                    finalURL = repairedURL
                    repaired = true
                }
            } catch {
                print("Studio repair failed: \(error)")
            }

            DispatchQueue.main.async {
                if let rawDoc = PDFDocument(url: finalURL), rawDoc.isEncrypted, rawDoc.isLocked {
                    self.finishEncryptedOpen(document: rawDoc, sourceURL: url, workingURL: finalURL, access: effectiveAccess, isRepaired: repaired)
                    return
                }

                self.validationRunner.openDocument(at: finalURL,
                                                   quickValidationPageLimit: 0,
                                                   progress: { [weak self] processed, total in
                                                       guard let self else { return }
                                                       guard total > 0 else { return }
                                                       let clamped = min(processed, total)
                                                       loadingStatus = "Validating \(clamped)/\(total)"
                                                   },
                                                   completion: { [weak self] result in
                                                       guard let self else { return }
                                                       isDocumentLoading = false
                                                       loadingStatus = nil
                                                       switch result {
                                                       case let .success(doc):
                                                           finishOpen(document: doc, sourceURL: url, workingURL: finalURL, access: effectiveAccess, isRepaired: repaired)
                                                       case let .failure(error):
                                                           handleOpenError(error)
                                                       }
                                                   })
            }
        }
    }

    private func finishEncryptedOpen(document rawDoc: PDFDocument,
                                     sourceURL: URL,
                                     workingURL: URL,
                                     access: SecurityScopedAccess?,
                                     isRepaired: Bool)
    {
        loadingStatus = "Unlocking \(sourceURL.lastPathComponent)…"
        guard PDFPasswordUnlock.unlockIfNeeded(document: rawDoc, url: sourceURL, passwordProvider: passwordProvider) else {
            if let studioOpenSignpost {
                PerfLog.end("StudioOpen", studioOpenSignpost)
                self.studioOpenSignpost = nil
            }
            resetDocumentState()
            pushLog("Open failed: password required for \(sourceURL.lastPathComponent)")
            return
        }

        isDocumentLoading = false
        loadingStatus = nil
        finishOpen(document: rawDoc,
                   sourceURL: sourceURL,
                   workingURL: workingURL,
                   access: access,
                   isRepaired: isRepaired,
                   requiresUnlockedValidation: true)
    }

    private func finishOpen(document newDocument: PDFDocument,
                            sourceURL: URL,
                            workingURL: URL,
                            access: SecurityScopedAccess?,
                            isRepaired: Bool = false,
                            requiresUnlockedValidation: Bool = false)
    {
        let sp = PerfLog.begin("StudioFinishOpen")
        defer { PerfLog.end("StudioFinishOpen", sp) }
        clearEditUndoStacks()
        document = newDocument
        currentURL = workingURL
        self.sourceURL = sourceURL
        activeSecurityScope = access
        let profile = DocumentProfile.from(pageCount: newDocument.pageCount)
        isLargeDocument = profile.isLarge
        isMassiveDocument = profile.isMassive
        deferOutlineLoad = isMassiveDocument
        deferAnnotationScan = isMassiveDocument
        resetThumbnailState()
        let isMassive = isMassiveDocument
        if isMassive {
            logMassiveDocument(pageCount: newDocument.pageCount, url: workingURL)
        }

        pdfView?.document = newDocument
        applyPDFViewConfiguration()
        refreshAll()
        pushLog("Opened \(sourceURL.lastPathComponent)")
        validationStatus = nil
        validationMode = .idle
        isFullValidationRunning = false
        self.isRepaired = isRepaired
        self.requiresUnlockedValidation = requiresUnlockedValidation

        let shouldSkipAutoValidation = DocumentValidationRunner.shouldSkipQuickValidation(
            estimatedPages: nil,
            resolvedPageCount: newDocument.pageCount
        ) || requiresUnlockedValidation
        skippedQuickValidation = shouldSkipAutoValidation
        if !isMassive, !shouldSkipAutoValidation {
            scheduleValidation(for: workingURL, pageLimit: 10, mode: .quick)
        }

        if let openSP = studioOpenSignpost {
            PerfLog.end("StudioOpen", openSP)
            studioOpenSignpost = nil
        }
        #if DEBUG
            if let start = studioOpenStart {
                let duration = Date().timeIntervalSince(start)
                PerfMetrics.shared.recordStudioOpen(duration: duration)
                NSLog("%@", PerfMetrics.shared.summaryString())
                studioOpenStart = nil
            }
        #endif
    }

    private func handleOpenError(_ error: Error) {
        if let openSP = studioOpenSignpost {
            PerfLog.end("StudioOpen", openSP)
            studioOpenSignpost = nil
        }
        resetDocumentState()
        pushLog("⚠️ \(error.localizedDescription)")
        present(error)
    }

    /// Closes the current document and resets all state.
    func closeDocument() {
        resetDocumentState(clearLog: true)
    }

    private func resetDocumentState(clearLog: Bool = false) {
        validationRunner.cancelValidation()
        validationRunner.cancelOpen()
        clearSearchState()
        isDocumentLoading = false
        loadingStatus = nil
        snapshotOperation?.cancel()
        snapshotOperation = nil
        clearEditUndoStacks()
        document = nil
        pdfView?.document = nil
        currentURL = nil
        sourceURL = nil
        activeSecurityScope = nil
        isLargeDocument = false
        isMassiveDocument = false
        skippedQuickValidation = false
        requiresUnlockedValidation = false
        deferOutlineLoad = false
        deferAnnotationScan = false
        resetThumbnailState()
        validationStatus = nil
        validationMode = .idle
        isFullValidationRunning = false
        pageSnapshots = []
        outlineRows = []
        isOutlineTruncated = false
        annotationRows = []
        selectedPageIDs = []
        selectedAnnotation = nil
        currentSelectionText = nil
        if clearLog {
            logMessages = []
        }
        isRepaired = false
        streamingLoader.close()
    }

    private func clearEditUndoStacks() {
        pdfView?.undoManager?.removeAllActions()
        editUndoManager.removeAllActions()
    }

    var canShowDocumentHealth: Bool {
        document != nil
    }

    var hasActiveSecurityScope: Bool {
        activeSecurityScope != nil
    }

    func showDocumentHealth() {
        guard canShowDocumentHealth else { return }
        isDocumentHealthPresented = true
    }

    var documentHealthSummary: DocumentHealthSummary? {
        guard let document else { return nil }
        let name = currentURL?.lastPathComponent ?? sourceURL?.lastPathComponent ?? "PDF"
        let quickFixResult = QuickFixResultStore.shared.result(primaryURL: currentURL, fallbackURL: sourceURL)
        return DocumentHealthSummary.build(
            documentName: name,
            pageCount: document.pageCount,
            isRepaired: isRepaired,
            isLargeDocument: isLargeDocument,
            isMassiveDocument: isMassiveDocument,
            skippedQuickValidation: skippedQuickValidation,
            validationStatus: validationStatus,
            quickFixResult: quickFixResult,
            documentAttributes: document.documentAttributes,
            hasReplacementTextAnnotations: PDFOps.containsReplacementTextAnnotations(in: document)
        )
    }

    func exportDocumentHealthReport() {
        guard let summary = documentHealthSummary else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = summary.documentName.replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive]) + "-health-report.txt"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try summary.plainTextReport().write(to: url, atomically: true, encoding: .utf8)
                pushLog("Exported health report to \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                pushLog("Health report export failed: \(error.localizedDescription)")
                present(error)
            }
        }
    }

    // MARK: - Selection & Editing

    private enum DragMode {
        case none
        case move(startPoint: CGPoint, originalBounds: CGRect)
        case resize(handle: ResizeHandle, startPoint: CGPoint, originalBounds: CGRect)
    }

    private enum ResizeHandle {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private struct PageBoundsChange {
        let page: PDFPage
        let oldMediaBox: CGRect
        let oldCropBox: CGRect
        let newMediaBox: CGRect
        let newCropBox: CGRect
    }

    private let selectionHandleSize: CGFloat = 6.0
    private var currentDragMode: DragMode = .none

    private var activeUndoManager: UndoManager {
        pdfView?.undoManager ?? editUndoManager
    }

    func undoLastEdit() {
        activeUndoManager.undo()
    }

    func redoLastEdit() {
        activeUndoManager.redo()
    }

    func selectAnnotation(_ annotation: PDFAnnotation) {
        guard !isMassiveDocument else { return }
        // If already selected, do nothing (or refresh?)
        if selectedAnnotation === annotation { return }

        // Invalidate old selection if it exists
        if let current = selectedAnnotation, let page = current.page {
            forceRedraw(rect: current.bounds.union(selectionHelperAnnotation?.bounds ?? .zero), on: page)
        }

        deselectAnnotation() // Clear previous (and invalidate its area)

        selectedAnnotation = annotation

        // Add visual feedback (SelectionAnnotation)
        if let page = annotation.page {
            // Use .square to avoid default stamp appearance
            let helper = SelectionAnnotation(bounds: annotation.bounds, forType: .square, withProperties: nil)
            helper.shouldPrint = false
            page.addAnnotation(helper)
            selectionHelperAnnotation = helper
            // Invalidate new selection area
            forceRedraw(rect: annotation.bounds.union(helper.bounds), on: page)
        }

        pushLog("Selected annotation: \(annotation.type ?? "Unknown")")
    }

    func deselectAnnotation() {
        if let helper = selectionHelperAnnotation {
            // Remove from page to prevent ghosts
            helper.page?.removeAnnotation(helper)

            // Invalidate area
            if let page = helper.page {
                forceRedraw(rect: helper.bounds, on: page)
            }
            selectionHelperAnnotation = nil
        }

        if let current = selectedAnnotation, let page = current.page {
            // Invalidate old selection bounds too
            forceRedraw(rect: current.bounds, on: page)
        }

        selectedAnnotation = nil
        selectionHelperAnnotation = nil
        refreshAnnotations()
    }

    // MARK: - Page Rotation

    func rotateCurrentPageLeft() {
        guard let page = currentPDFPage else { return }
        let oldRotation = page.rotation
        let newRotation = (oldRotation - 90).normalizedRotation
        page.rotation = newRotation
        notifyPageRotationChanged()
        registerRotationUndo(page: page, oldRotation: oldRotation, newRotation: newRotation)
    }

    func rotateCurrentPageRight() {
        guard let page = currentPDFPage else { return }
        let oldRotation = page.rotation
        let newRotation = (oldRotation + 90).normalizedRotation
        page.rotation = newRotation
        notifyPageRotationChanged()
        registerRotationUndo(page: page, oldRotation: oldRotation, newRotation: newRotation)
    }

    private var currentPDFPage: PDFPage? {
        if let pdfView, let page = pdfView.currentPage {
            return page
        }
        return nil
    }

    private func notifyPageRotationChanged() {
        // Refresh thumbnails if needed
        if let page = currentPDFPage, let doc = document {
            let index = doc.index(for: page)
            if index >= 0 {
                // Invalidate thumbnail
                ensureThumbnail(for: index)
            }
        }
    }

    private func registerRotationUndo(page: PDFPage, oldRotation: Int, newRotation: Int) {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { [weak self] _ in
            guard let self else { return }
            page.rotation = oldRotation
            notifyPageRotationChanged()
            registerRotationUndo(page: page, oldRotation: newRotation, newRotation: oldRotation)
        }
        undoManager.setActionName("Rotate Page")
    }

    private func logMassiveDocument(pageCount: Int, url: URL?) {
        NSLog("PDFPerfTelemetry: massiveDocEnabled pageCount=%d file=%@", pageCount, url?.lastPathComponent ?? "unknown")
    }

    func deleteSelectedAnnotation() {
        guard let annotation = selectedAnnotation, let page = annotation.page else { return }

        registerAnnotationRemoval(annotation, on: page, actionName: "Delete Annotation")

        deselectAnnotation()
        page.removeAnnotation(annotation)
        refreshAnnotations()
        pushLog("Deleted annotation")
    }

    func editAnnotation(_ row: AnnotationRow, contents: String) {
        editAnnotation(row.annotation, contents: contents, urlString: nil)
    }

    func editAnnotation(_ row: AnnotationRow, draft: AnnotationEditDraft) {
        editAnnotation(row.annotation, contents: draft.contents, urlString: draft.urlString)
    }

    func editAnnotation(_ annotation: PDFAnnotation, contents: String, urlString: String? = nil) {
        let oldContents = annotation.contents
        let newContents = PDFStringNormalizer.normalizedNonEmpty(contents, context: "annotation contents")
        let oldURL = annotation.url
        let newURL = urlString.flatMap(Self.annotationURL)
        guard oldContents != newContents || oldURL != newURL else { return }
        registerAnnotationEditUndo(annotation: annotation,
                                   oldContents: oldContents,
                                   oldURL: oldURL,
                                   newContents: newContents,
                                   newURL: newURL)
        annotation.contents = newContents
        if urlString != nil {
            annotation.url = newURL
        }
        refreshAnnotations()
        pushLog("Edited annotation")
    }

    private func registerAnnotationEditUndo(annotation: PDFAnnotation,
                                            oldContents: String?,
                                            oldURL: URL?,
                                            newContents: String?,
                                            newURL: URL?)
    {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            annotation.contents = oldContents
            annotation.url = oldURL
            target.refreshAnnotations()
            target.registerAnnotationEditUndo(annotation: annotation,
                                              oldContents: newContents,
                                              oldURL: newURL,
                                              newContents: oldContents,
                                              newURL: oldURL)
        }
        undoManager.setActionName("Edit Annotation")
    }

    private static func annotationURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    func replaceSelectedText(with replacement: String) {
        guard let selection = pdfView?.currentSelection else { return }
        let sanitized = PDFStringNormalizer.normalizedNonEmpty(replacement, context: "replacement text") ?? ""
        guard !sanitized.isEmpty else { return }

        var additions: [PDFAnnotation] = []
        for page in selection.pages {
            for rect in annotationRects(for: selection, on: page) {
                let cover = PDFAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), forType: .square, withProperties: nil)
                cover.color = .white
                cover.interiorColor = .white
                cover.userName = PDFOps.replacementTextAnnotationUserName
                let coverBorder = PDFBorder()
                coverBorder.lineWidth = 0
                cover.border = coverBorder
                page.addAnnotation(cover)
                additions.append(cover)

                let text = PDFAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), forType: .freeText, withProperties: nil)
                text.contents = sanitized
                text.font = NSFont.systemFont(ofSize: max(9, min(rect.height * 0.7, 14)))
                text.fontColor = .black
                text.color = .clear
                text.backgroundColor = .clear
                text.userName = PDFOps.replacementTextAnnotationUserName
                page.addAnnotation(text)
                additions.append(text)
            }
        }

        registerAnnotationAdditions(additions, actionName: "Replace Text")
        refreshAnnotations()
        pushLog("Replaced selected text")
    }

    func redactSelectedText() {
        guard let selection = pdfView?.currentSelection else { return }

        var additions: [PDFAnnotation] = []
        for page in selection.pages {
            for rect in annotationRects(for: selection, on: page) {
                let cover = PDFAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), forType: .square, withProperties: nil)
                cover.color = .black
                cover.interiorColor = .black
                cover.userName = PDFOps.replacementTextAnnotationUserName
                let border = PDFBorder()
                border.lineWidth = 0
                cover.border = border
                page.addAnnotation(cover)
                additions.append(cover)
            }
        }

        registerAnnotationAdditions(additions, actionName: "Redact Text")
        refreshAnnotations()
        pushLog("Redacted selected text")
    }

    @MainActor
    func replaceSelectedTextWithPrompt() {
        guard pdfView?.currentSelection != nil else { return }
        let field = NSTextField(string: "")
        field.placeholderString = "Replacement text"
        field.frame = CGRect(x: 0, y: 0, width: 340, height: 24)

        let alert = NSAlert()
        alert.messageText = "Replace Selected Text"
        alert.informativeText = "PDFQuickFix will cover the selected text and place editable replacement text on top."
        alert.accessoryView = field
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        replaceSelectedText(with: field.stringValue)
    }

    @MainActor
    func redactSelectedTextWithConfirmation() {
        guard pdfView?.currentSelection != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Redact Selected Text"
        alert.informativeText = "PDFQuickFix will cover the selected text. Export a flattened or sanitized copy before sharing so the original text layer is removed."
        alert.addButton(withTitle: "Redact")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        redactSelectedText()
    }

    private func annotationRects(for selection: PDFSelection, on page: PDFPage) -> [CGRect] {
        let perLine = selection.selectionsByLine()
        let rects = perLine
            .filter { $0.pages.contains(page) }
            .map { $0.bounds(for: page) }
            .filter { !$0.isEmpty }
        if !rects.isEmpty { return rects }
        let fallback = selection.bounds(for: page)
        return fallback.isEmpty ? [] : [fallback]
    }

    func handleMouseDown(in view: PDFView, with event: NSEvent) -> Bool {
        guard !isMassiveDocument else { return false }
        let point = view.convert(event.locationInWindow, from: nil)

        guard let page = view.page(for: point, nearest: true) else {
            deselectAnnotation()
            return false
        }

        let pagePoint = view.convert(point, to: page)

        // 1. Check if we are hitting the currently selected annotation (or its handles)
        if let selected = selectedAnnotation, selected.page == page {
            if let mode = dragMode(for: pagePoint, annotation: selected) {
                // We hit the selection. Start dragging.
                currentDragMode = mode
                return true
            }
        }

        // 2. Check if we hit a new annotation
        if let annotation = page.annotation(at: pagePoint) {
            // Ignore our own selection helper if it somehow got hit directly
            if annotation is SelectionAnnotation { return true }

            selectAnnotation(annotation)

            // Check if we can drag this new annotation immediately
            if let mode = dragMode(for: pagePoint, annotation: annotation) {
                currentDragMode = mode
            }
            return true
        }

        // 3. Clicked empty space
        deselectAnnotation()
        return false
    }

    func handleMouseDragged(in view: PDFView, with event: NSEvent) {
        guard !isMassiveDocument, let annotation = selectedAnnotation, let page = annotation.page else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let pagePoint = view.convert(point, to: page)

        switch currentDragMode {
        case let .move(startPoint, originalBounds):
            let dx = pagePoint.x - startPoint.x
            let dy = pagePoint.y - startPoint.y
            let newBounds = CGRect(x: originalBounds.origin.x + dx,
                                   y: originalBounds.origin.y + dy,
                                   width: originalBounds.width,
                                   height: originalBounds.height)

            // Invalidate old area
            forceRedraw(rect: annotation.bounds.union(selectionHelperAnnotation?.bounds ?? .zero), on: page)

            annotation.bounds = newBounds
            selectionHelperAnnotation?.bounds = newBounds

            // Invalidate new area
            forceRedraw(rect: newBounds, on: page)

        case let .resize(handle, startPoint, originalBounds):
            let dx = pagePoint.x - startPoint.x
            let dy = pagePoint.y - startPoint.y

            var newBounds = originalBounds
            let minSize: CGFloat = 10

            switch handle {
            case .topLeft:
                let proposedWidth = originalBounds.width - dx
                let proposedHeight = originalBounds.height - dy
                let clampedWidth = max(minSize, proposedWidth)
                let clampedHeight = max(minSize, proposedHeight)
                let widthDelta = proposedWidth - clampedWidth
                let heightDelta = proposedHeight - clampedHeight
                newBounds.origin.x = originalBounds.origin.x + dx + widthDelta
                newBounds.origin.y = originalBounds.origin.y + dy + heightDelta
                newBounds.size.width = clampedWidth
                newBounds.size.height = clampedHeight
            case .topRight:
                let proposedWidth = originalBounds.width + dx
                let proposedHeight = originalBounds.height - dy
                let clampedWidth = max(minSize, proposedWidth)
                let clampedHeight = max(minSize, proposedHeight)
                let heightDelta = proposedHeight - clampedHeight
                newBounds.origin.y = originalBounds.origin.y + dy + heightDelta
                newBounds.size.width = clampedWidth
                newBounds.size.height = clampedHeight
            case .bottomLeft:
                let proposedWidth = originalBounds.width - dx
                let clampedWidth = max(minSize, proposedWidth)
                let widthDelta = proposedWidth - clampedWidth
                newBounds.origin.x = originalBounds.origin.x + dx + widthDelta
                newBounds.size.width = clampedWidth
                let proposedHeight = originalBounds.height + dy
                newBounds.size.height = max(minSize, proposedHeight)
            case .bottomRight:
                let proposedWidth = originalBounds.width + dx
                let proposedHeight = originalBounds.height + dy
                newBounds.size.width = max(minSize, proposedWidth)
                newBounds.size.height = max(minSize, proposedHeight)
            }

            // Invalidate old area
            forceRedraw(rect: annotation.bounds.union(selectionHelperAnnotation?.bounds ?? .zero), on: page)

            annotation.bounds = newBounds
            selectionHelperAnnotation?.bounds = newBounds

            // Invalidate new area
            forceRedraw(rect: newBounds, on: page)

        case .none:
            break
        }
    }

    func handleMouseUp(in _: PDFView, with _: NSEvent) {
        guard !isMassiveDocument, let annotation = selectedAnnotation, let page = annotation.page else { return }

        if case let .move(_, originalBounds) = currentDragMode {
            let finalBounds = annotation.bounds
            if finalBounds != originalBounds {
                registerBoundsChange(annotation: annotation, oldBounds: originalBounds, newBounds: finalBounds)
            }
        } else if case let .resize(_, _, originalBounds) = currentDragMode {
            let finalBounds = annotation.bounds
            if finalBounds != originalBounds {
                registerBoundsChange(annotation: annotation, oldBounds: originalBounds, newBounds: finalBounds)
            }
        }

        // Final redraw to ensure clean state
        forceRedraw(rect: annotation.bounds.union(selectionHelperAnnotation?.bounds ?? .zero), on: page)

        currentDragMode = .none
    }

    private func dragMode(for point: CGPoint, annotation: PDFAnnotation) -> DragMode? {
        let bounds = annotation.bounds
        let handleSize = selectionHandleSize
        let handles: [(ResizeHandle, CGRect)] = [
            (.bottomLeft, CGRect(origin: CGPoint(x: bounds.minX, y: bounds.minY), size: CGSize(width: handleSize, height: handleSize))),
            (.bottomRight, CGRect(origin: CGPoint(x: bounds.maxX - handleSize, y: bounds.minY), size: CGSize(width: handleSize, height: handleSize))),
            (.topLeft, CGRect(origin: CGPoint(x: bounds.minX, y: bounds.maxY - handleSize), size: CGSize(width: handleSize, height: handleSize))),
            (.topRight, CGRect(origin: CGPoint(x: bounds.maxX - handleSize, y: bounds.maxY - handleSize), size: CGSize(width: handleSize, height: handleSize))),
        ]
        if let match = handles.first(where: { $0.1.insetBy(dx: -2, dy: -2).contains(point) }) {
            return .resize(handle: match.0, startPoint: point, originalBounds: bounds)
        }
        if bounds.contains(point) {
            return .move(startPoint: point, originalBounds: bounds)
        }
        return nil
    }

    private func registerBoundsChange(annotation: PDFAnnotation, oldBounds: CGRect, newBounds: CGRect) {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            annotation.bounds = oldBounds
            target.selectionHelperAnnotation?.bounds = oldBounds
            target.registerBoundsChange(annotation: annotation, oldBounds: newBounds, newBounds: oldBounds)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName("Move/Resize Annotation")
        }
    }

    func registerAnnotationAddition(_ annotation: PDFAnnotation, actionName: String = "Add Annotation") {
        guard let page = annotation.page else { return }
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            target.clearSelectedAnnotationIfNeeded(annotation)
            page.removeAnnotation(annotation)
            target.refreshAnnotations()
            target.registerAnnotationRemoval(annotation, on: page, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerAnnotationRemoval(_ annotation: PDFAnnotation, on page: PDFPage, actionName: String) {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            page.addAnnotation(annotation)
            target.selectAnnotation(annotation)
            target.refreshAnnotations()
            target.registerAnnotationAddition(annotation, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerAnnotationAdditions(_ annotations: [PDFAnnotation], actionName: String) {
        let entries = annotations.compactMap { annotation -> (PDFAnnotation, PDFPage)? in
            guard let page = annotation.page else { return nil }
            return (annotation, page)
        }
        guard !entries.isEmpty else { return }

        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            for (annotation, page) in entries {
                target.clearSelectedAnnotationIfNeeded(annotation)
                page.removeAnnotation(annotation)
            }
            target.refreshAnnotations()
            target.registerAnnotationRemovals(entries, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerAnnotationRemovals(_ entries: [(PDFAnnotation, PDFPage)], actionName: String) {
        guard !entries.isEmpty else { return }
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            for (annotation, page) in entries {
                page.addAnnotation(annotation)
            }
            target.refreshAnnotations()
            target.registerAnnotationAdditions(entries.map(\.0), actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func clearSelectedAnnotationIfNeeded(_ annotation: PDFAnnotation) {
        guard selectedAnnotation === annotation else { return }
        deselectAnnotation()
    }

    private func detachSelectionHelperForPersistence() -> (SelectionAnnotation, PDFPage)? {
        guard let helper = selectionHelperAnnotation as? SelectionAnnotation,
              let page = helper.page else { return nil }
        page.removeAnnotation(helper)
        selectionHelperAnnotation = nil
        return (helper, page)
    }

    private func restoreSelectionHelperAfterPersistence(_ detached: (SelectionAnnotation, PDFPage)?) {
        guard let (helper, page) = detached,
              selectedAnnotation?.page === page
        else { return }
        page.addAnnotation(helper)
        selectionHelperAnnotation = helper
    }

    private func newAnnotations(after operation: () -> Void) -> [PDFAnnotation] {
        guard let document else {
            operation()
            return []
        }
        let before = annotationIdentitySnapshot(in: document)
        operation()
        return addedAnnotations(in: document, after: before)
    }

    private func annotationIdentitySnapshot(in document: PDFDocument) -> [PDFPage: Set<ObjectIdentifier>] {
        var snapshot: [PDFPage: Set<ObjectIdentifier>] = [:]
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            snapshot[page] = Set(page.annotations.map { ObjectIdentifier($0) })
        }
        return snapshot
    }

    private func addedAnnotations(in document: PDFDocument, after snapshot: [PDFPage: Set<ObjectIdentifier>]) -> [PDFAnnotation] {
        var additions: [PDFAnnotation] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let known = snapshot[page] ?? []
            additions.append(contentsOf: page.annotations.filter { !known.contains(ObjectIdentifier($0)) })
        }
        return additions
    }

    private func registerPageBoundsChange(_ changes: [PageBoundsChange], actionName: String) {
        guard !changes.isEmpty else { return }
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            for change in changes {
                change.page.setBounds(change.oldMediaBox, for: .mediaBox)
                change.page.setBounds(change.oldCropBox, for: .cropBox)
            }
            target.refreshPages()
            target.registerPageBoundsChange(changes.map {
                PageBoundsChange(page: $0.page,
                                 oldMediaBox: $0.newMediaBox,
                                 oldCropBox: $0.newCropBox,
                                 newMediaBox: $0.oldMediaBox,
                                 newCropBox: $0.oldCropBox)
            }, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerOutlineInsertion(_ outline: PDFOutline,
                                          parent: PDFOutline,
                                          document: PDFDocument,
                                          index: Int,
                                          createdRoot: Bool,
                                          actionName: String)
    {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            outline.removeFromParent()
            if createdRoot {
                document.outlineRoot = nil
            }
            target.refreshOutline()
            target.registerOutlineRemoval(outline,
                                          parent: parent,
                                          document: document,
                                          index: index,
                                          createdRoot: createdRoot,
                                          actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerOutlineRemoval(_ outline: PDFOutline,
                                        parent: PDFOutline,
                                        document: PDFDocument,
                                        index: Int,
                                        createdRoot: Bool,
                                        actionName: String)
    {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            if createdRoot {
                document.outlineRoot = parent
            }
            let insertionIndex = min(max(index, 0), parent.numberOfChildren)
            parent.insertChild(outline, at: insertionIndex)
            target.refreshOutline()
            target.registerOutlineInsertion(outline,
                                            parent: parent,
                                            document: document,
                                            index: insertionIndex,
                                            createdRoot: createdRoot,
                                            actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerOutlineRename(_ outline: PDFOutline, oldLabel: String?, newLabel: String?, actionName: String) {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            outline.label = oldLabel
            target.refreshOutline()
            target.registerOutlineRename(outline, oldLabel: newLabel, newLabel: oldLabel, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func outlineChildIndex(_ outline: PDFOutline, in parent: PDFOutline) -> Int? {
        for index in 0 ..< parent.numberOfChildren {
            if parent.child(at: index) === outline {
                return index
            }
        }
        return nil
    }

    private func registerMetadataChange(document: PDFDocument,
                                        oldAttributes: [AnyHashable: Any]?,
                                        newAttributes: [AnyHashable: Any]?,
                                        actionName: String)
    {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            document.documentAttributes = oldAttributes
            target.registerMetadataChange(document: document,
                                          oldAttributes: newAttributes,
                                          newAttributes: oldAttributes,
                                          actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    func cursor(for point: CGPoint, in view: PDFView) -> NSCursor? {
        guard !isMassiveDocument else { return nil }
        guard let page = view.page(for: point, nearest: true) else { return nil }
        let pagePoint = view.convert(point, to: page)

        // 1. Check resize handles if an annotation is selected
        if let annotation = selectedAnnotation, annotation.page == page {
            if let mode = dragMode(for: pagePoint, annotation: annotation) {
                switch mode {
                case let .resize(handle, _, _):
                    switch handle {
                    case .topLeft, .bottomRight: return .crosshair // Or diagonal resize
                    case .topRight, .bottomLeft: return .crosshair
                    }
                case .move:
                    return .openHand
                case .none:
                    break
                }
            }
        }

        // 2. Check if hovering over any other annotation
        if let _ = page.annotation(at: pagePoint) {
            return .pointingHand
        }

        return nil
    }

    private func forceRedraw(rect: CGRect, on page: PDFPage) {
        renderThrottle.schedule { [weak self] in
            guard let self, let view = pdfView else { return }
            let viewRect = view.convert(rect, from: page)
            // Expand slightly to cover anti-aliasing/handles
            let expanded = viewRect.insetBy(dx: -10, dy: -10)
            view.setNeedsDisplay(expanded)
        }
    }

    func setDocument(_ document: PDFDocument?, url: URL? = nil) {
        validationRunner.cancelValidation()
        clearEditUndoStacks()
        clearSearchState()
        self.document = document
        if let url {
            currentURL = url
            // If setting document manually, we assume source=working unless specified otherwise.
            // But this method is mostly for save-as or internal updates.
            // Let's assume it updates working URL.
        }
        let profile = DocumentProfile.from(pageCount: document?.pageCount ?? 0)
        isLargeDocument = profile.isLarge
        isMassiveDocument = profile.isMassive
        deferOutlineLoad = isMassiveDocument
        deferAnnotationScan = isMassiveDocument

        // Initialize streaming loader for massive documents
        if isMassiveDocument, let url = currentURL ?? document?.documentURL {
            _ = streamingLoader.open(url: url)
        } else {
            streamingLoader.close()
        }

        resetThumbnailState()
        pdfView?.document = document
        applyPDFViewConfiguration()
        refreshSelectionState()
        refreshAll()
    }

    func runFullValidation() {
        guard let url = currentURL, document != nil, !isFullValidationRunning else { return }
        guard !requiresUnlockedValidation else {
            skippedQuickValidation = true
            validationMode = .idle
            isFullValidationRunning = false
            validationStatus = nil
            pushLog("Full validation skipped for encrypted PDF. Export an unlocked, sanitized copy before validating.")
            return
        }
        scheduleValidation(for: url, pageLimit: nil, mode: .full)
    }

    func refreshAll() {
        refreshPages()
        if deferOutlineLoad {
            outlineRows = []
            isOutlineTruncated = false
        } else {
            refreshOutline()
        }
        if deferAnnotationScan {
            annotationRows = []
        } else {
            refreshAnnotations()
        }
    }

    // MARK: - Search

    func find(_ text: String) {
        searchMatches.removeAll()
        currentMatchIndex = nil
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            document?.cancelFindString()
            if let findObserver {
                NotificationCenter.default.removeObserver(findObserver)
                self.findObserver = nil
            }
            return
        }
        guard let doc = document else { return }

        if let findObserver {
            NotificationCenter.default.removeObserver(findObserver)
            self.findObserver = nil
        }
        findObserver = NotificationCenter.default.addObserver(
            forName: .PDFDocumentDidFindMatch,
            object: doc,
            queue: .main
        ) { [weak self] note in
            guard let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                searchMatches.append(selection)
                if let index = searchMatches.indices.last, currentMatchIndex == nil {
                    focusSelection(selection, at: index)
                }
            }
        }

        doc.cancelFindString()
        doc.beginFindString(query, withOptions: [.caseInsensitive])
    }

    func updateSearchQueryDebounced(_ text: String) {
        searchDebounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.find(text)
        }
        searchDebounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func focusSelection(_ selection: PDFSelection, at index: Int? = nil) {
        selection.color = .yellow.withAlphaComponent(0.35)
        pdfView?.setCurrentSelection(selection, animate: true)
        pdfView?.go(to: selection)
        currentMatchIndex = index ?? searchMatches.firstIndex(of: selection)
    }

    func findNext() {
        guard !searchMatches.isEmpty else { return }
        let nextIndex: Int = if let currentMatchIndex {
            (currentMatchIndex + 1) % searchMatches.count
        } else {
            0
        }
        focusSelection(searchMatches[nextIndex], at: nextIndex)
    }

    func findPrev() {
        guard !searchMatches.isEmpty else { return }
        let previousIndex: Int = if let currentMatchIndex {
            (currentMatchIndex - 1 + searchMatches.count) % searchMatches.count
        } else {
            max(searchMatches.count - 1, 0)
        }
        focusSelection(searchMatches[previousIndex], at: previousIndex)
    }

    private func clearSearchState() {
        document?.cancelFindString()
        searchDebounceWorkItem?.cancel()
        searchDebounceWorkItem = nil
        if let findObserver {
            NotificationCenter.default.removeObserver(findObserver)
            self.findObserver = nil
        }
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = nil
    }

    func refreshPages() {
        snapshotOperation?.cancel()
        snapshotOperation = nil
        snapshotGenerationID = UUID()

        guard let doc = document else {
            snapshotOperation = nil
            pageSnapshots = []
            isThumbnailsLoading = false
            return
        }
        let pageCount = doc.pageCount
        guard pageCount > 0 else {
            snapshotOperation = nil
            pageSnapshots = []
            isThumbnailsLoading = false
            return
        }

        if isMassiveDocument {
            // Use virtualized provider for massive documents
            virtualPageProvider.configure(pageCount: pageCount, forceVirtualize: true)
            pageSnapshots = virtualPageProvider.visibleSnapshots
            isThumbnailsLoading = false
            return
        }

        if isLargeDocument {
            // For large (but not massive) docs, use provider but don't virtualize
            virtualPageProvider.configure(pageCount: pageCount, forceVirtualize: false)
            pageSnapshots = virtualPageProvider.visibleSnapshots
            isThumbnailsLoading = false
            return
        }

        isThumbnailsLoading = true

        let token = snapshotGenerationID
        let count = pageCount
        pageSnapshots = (0 ..< count).map { index in
            PageSnapshot(id: index,
                         index: index,
                         thumbnail: thumbnailCache.object(forKey: NSNumber(value: index)),
                         label: "Page \(index + 1)")
        }

        // Initial prefetch around the first page.
        prefetchThumbnails(around: 0, window: 2, farWindow: 6)

        // Mark loading finished; subsequent thumbnails will arrive via ensureThumbnail + renderService.
        if token == snapshotGenerationID {
            isThumbnailsLoading = false
        }
    }

    func refreshOutline(preserving preservedOutlines: [PDFOutline]? = nil) {
        if deferOutlineLoad, isMassiveDocument { return }
        deferOutlineLoad = false
        let limit = isMassiveDocument ? PDFOutlineLoader.massiveDocumentRowLimit : nil
        let result = PDFOutlineLoader.rows(from: document?.outlineRoot, limit: limit)
        var rows = result.rows
        let outlinesToPreserve = outlineRows.map(\.outline) + (preservedOutlines ?? [])
        if !outlinesToPreserve.isEmpty {
            var visibleIDs = Set(rows.map { ObjectIdentifier($0.outline) })
            for outline in outlinesToPreserve
                where !visibleIDs.contains(ObjectIdentifier(outline)) && outlineBelongsToCurrentDocument(outline)
            {
                rows.append(OutlineRow(outline: outline, depth: outlineDepth(outline)))
                visibleIDs.insert(ObjectIdentifier(outline))
            }
        }
        outlineRows = rows
        isOutlineTruncated = result.isTruncated
    }

    private func outlineBelongsToCurrentDocument(_ outline: PDFOutline) -> Bool {
        guard let root = document?.outlineRoot else { return false }
        var parent = outline.parent
        while let current = parent {
            if current === root { return true }
            parent = current.parent
        }
        return false
    }

    private func outlineDepth(_ outline: PDFOutline) -> Int {
        var depth = 0
        var parent = outline.parent
        while let current = parent, current !== document?.outlineRoot {
            depth += 1
            parent = current.parent
        }
        return depth
    }

    func loadOutlineIfNeeded() {
        guard isMassiveDocument else { return }
        deferOutlineLoad = false
        refreshOutline()
    }

    func refreshAnnotations() {
        if deferAnnotationScan, isMassiveDocument { return }
        deferAnnotationScan = false
        guard let doc = document else {
            annotationRows = []
            return
        }
        guard !(isLargeDocument && !isMassiveDocument) else {
            annotationRows = []
            return
        }
        var rows: [AnnotationRow] = []
        for index in 0 ..< doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            for annotation in page.annotations {
                if annotation is SelectionAnnotation { continue }
                rows.append(AnnotationRow(annotation: annotation, pageIndex: index))
            }
        }
        annotationRows = rows
    }

    func loadAnnotationsIfNeeded() {
        guard isMassiveDocument else { return }
        deferAnnotationScan = false
        refreshAnnotations()
    }

    func goTo(page index: Int) {
        guard let page = document?.page(at: index) else { return }
        pdfView?.go(to: page)
    }

    func movePages(from source: IndexSet, to destination: Int) {
        guard let doc = document else { return }
        let previousOrder = pageOrder(in: doc)
        let previousSelection = selectedPageIDs
        let pages = source.sorted().compactMap { doc.page(at: $0) }
        guard !pages.isEmpty else { return }
        for index in source.sorted(by: >) {
            doc.removePage(at: index)
        }
        var insertIndex = destination
        for page in pages {
            if insertIndex > doc.pageCount {
                insertIndex = doc.pageCount
            }
            doc.insert(page, at: insertIndex)
            insertIndex += 1
        }
        selectedPageIDs = []
        refreshPages()
        registerPageOrderChange(previousOrder: previousOrder,
                                nextOrder: pageOrder(in: doc),
                                previousSelection: previousSelection,
                                nextSelection: selectedPageIDs,
                                actionName: "Reorder Pages")
        pushLog("Reordered \(pages.count) page(s)")
    }

    func movePage(at index: Int, to newIndex: Int) {
        guard let doc = document,
              let page = doc.page(at: index),
              index != newIndex else { return }
        let previousOrder = pageOrder(in: doc)
        let previousSelection = selectedPageIDs
        doc.removePage(at: index)
        let destination = max(0, min(newIndex, doc.pageCount))
        doc.insert(page, at: destination)
        selectedPageIDs = Set([destination])
        refreshPages()
        registerPageOrderChange(previousOrder: previousOrder,
                                nextOrder: pageOrder(in: doc),
                                previousSelection: previousSelection,
                                nextSelection: selectedPageIDs,
                                actionName: "Move Page")
        pushLog("Moved page \(index + 1) to \(destination + 1)")
    }

    @discardableResult
    func deleteSelectedPages() -> Bool {
        guard let doc = document else { return false }
        let targets = selectedPageIDs.sorted(by: >)
        guard !targets.isEmpty else { return false }
        let removedPages: [(index: Int, page: PDFPage)] = targets.compactMap { index in
            guard index < doc.pageCount, let page = doc.page(at: index) else { return nil }
            return (index, page)
        }
        for index in targets {
            guard index < doc.pageCount else { continue }
            doc.removePage(at: index)
        }
        selectedPageIDs = []
        refreshPages()
        registerPageDeletionUndo(removedPages: removedPages, actionName: "Delete Page")
        pushLog("Deleted \(targets.count) page(s)")
        return true
    }

    @discardableResult
    func duplicateSelectedPages() -> Bool {
        guard let doc = document else { return false }
        let targets = selectedPageIDs.sorted(by: >)
        guard !targets.isEmpty else { return false }
        var insertedPages: [PDFPage] = []
        for index in targets {
            guard let page = doc.page(at: index),
                  let clone = page.copy() as? PDFPage else { continue }
            doc.insert(clone, at: index + 1)
            insertedPages.append(clone)
        }
        refreshPages()
        registerPageInsertionUndo(insertedPages: insertedPages, actionName: "Duplicate Page")
        pushLog("Duplicated \(targets.count) page(s)")
        return true
    }

    @discardableResult
    func insertBlankPage(after index: Int? = nil) -> Bool {
        guard let doc = document else { return false }
        let insertionIndex = boundedInsertionIndex(after: index)
        guard let page = makeBlankPage(referenceIndex: insertionIndex - 1) else { return false }
        doc.insert(page, at: insertionIndex)
        selectedPageIDs = [insertionIndex]
        refreshPages()
        registerPageInsertionUndo(insertedIndices: [insertionIndex], actionName: "Insert Blank Page")
        goTo(page: insertionIndex)
        pushLog("Inserted blank page at \(insertionIndex + 1)")
        return true
    }

    func importPagesFromFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose PDFs or images to insert into the current document"
        if panel.runModal() == .OK {
            let count = importPages(from: panel.urls, after: selectedPageIDs.sorted().last)
            if count > 0 {
                pushLog("Imported \(count) page(s) from \(panel.urls.count) file(s)")
            } else {
                pushLog("Import failed: no pages could be created from the selected file(s)")
            }
        }
    }

    @discardableResult
    func importPages(from source: PDFDocument, after index: Int? = nil) -> Int {
        guard let doc = document, source.pageCount > 0 else { return 0 }
        let insertionIndex = boundedInsertionIndex(after: index)
        var inserted = 0
        for sourceIndex in 0 ..< source.pageCount {
            guard let page = source.page(at: sourceIndex),
                  let copy = page.copy() as? PDFPage
            else { continue }
            doc.insert(copy, at: insertionIndex + inserted)
            inserted += 1
        }
        guard inserted > 0 else { return 0 }
        selectedPageIDs = Set(insertionIndex ..< insertionIndex + inserted)
        refreshPages()
        registerPageInsertionUndo(insertedIndices: Array(insertionIndex ..< insertionIndex + inserted), actionName: "Import Pages")
        goTo(page: insertionIndex)
        return inserted
    }

    @discardableResult
    func importPages(from urls: [URL], after index: Int? = nil) -> Int {
        guard let doc = document, !urls.isEmpty else { return 0 }
        let insertionIndex = boundedInsertionIndex(after: index)
        var inserted = 0
        for url in urls {
            for page in makeImportPages(from: url) {
                doc.insert(page, at: insertionIndex + inserted)
                inserted += 1
            }
        }
        guard inserted > 0 else { return 0 }
        selectedPageIDs = Set(insertionIndex ..< insertionIndex + inserted)
        refreshPages()
        registerPageInsertionUndo(insertedIndices: Array(insertionIndex ..< insertionIndex + inserted), actionName: "Import Pages")
        goTo(page: insertionIndex)
        return inserted
    }

    private func registerPageInsertionUndo(insertedIndices: [Int], actionName: String) {
        guard !insertedIndices.isEmpty else { return }
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            guard let doc = target.document else { return }
            var removedPages: [(index: Int, page: PDFPage)] = []
            for index in insertedIndices.sorted(by: >) {
                guard index < doc.pageCount, let page = doc.page(at: index) else { continue }
                doc.removePage(at: index)
                removedPages.append((index, page))
            }
            target.selectedPageIDs = []
            target.refreshPages()
            target.registerPageDeletionUndo(removedPages: removedPages, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerPageInsertionUndo(insertedPages: [PDFPage], actionName: String) {
        guard !insertedPages.isEmpty else { return }
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            guard let doc = target.document else { return }
            var removedPages: [(index: Int, page: PDFPage)] = []
            for page in insertedPages {
                let index = doc.index(for: page)
                guard index != NSNotFound else { continue }
                doc.removePage(at: index)
                removedPages.append((index, page))
            }
            target.selectedPageIDs = []
            target.refreshPages()
            target.registerPageDeletionUndo(removedPages: removedPages, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerPageDeletionUndo(removedPages: [(index: Int, page: PDFPage)], actionName: String) {
        guard !removedPages.isEmpty else { return }
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            guard let doc = target.document else { return }
            var restoredIndices: [Int] = []
            for item in removedPages.sorted(by: { $0.index < $1.index }) {
                let index = max(0, min(item.index, doc.pageCount))
                doc.insert(item.page, at: index)
                restoredIndices.append(index)
            }
            target.selectedPageIDs = Set(restoredIndices)
            target.refreshPages()
            target.registerPageInsertionUndo(insertedIndices: restoredIndices, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerPageOrderChange(previousOrder: [PDFPage],
                                         nextOrder: [PDFPage],
                                         previousSelection: Set<Int>,
                                         nextSelection: Set<Int>,
                                         actionName: String)
    {
        guard previousOrder.map(ObjectIdentifier.init) != nextOrder.map(ObjectIdentifier.init) else { return }
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            target.applyPageOrder(previousOrder, selection: previousSelection)
            target.registerPageOrderChange(previousOrder: nextOrder,
                                           nextOrder: previousOrder,
                                           previousSelection: nextSelection,
                                           nextSelection: previousSelection,
                                           actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func pageOrder(in document: PDFDocument) -> [PDFPage] {
        (0 ..< document.pageCount).compactMap { document.page(at: $0) }
    }

    private func applyPageOrder(_ pages: [PDFPage], selection: Set<Int>) {
        guard let doc = document else { return }
        if doc.pageCount > 0 {
            for index in stride(from: doc.pageCount - 1, through: 0, by: -1) {
                doc.removePage(at: index)
            }
        }
        for (index, page) in pages.enumerated() {
            doc.insert(page, at: index)
        }
        selectedPageIDs = selection
        refreshPages()
    }

    private func boundedInsertionIndex(after index: Int?) -> Int {
        guard let doc = document else { return 0 }
        let anchor = index ?? selectedPageIDs.sorted().last ?? currentDisplayedPageIndex()
        guard let anchor else { return doc.pageCount }
        return max(0, min(anchor + 1, doc.pageCount))
    }

    private func makeBlankPage(referenceIndex: Int) -> PDFPage? {
        let fallbackSize = CGSize(width: 612, height: 792)
        let referenceSize = document?
            .page(at: max(0, min(referenceIndex, (document?.pageCount ?? 1) - 1)))?
            .bounds(for: .mediaBox)
            .size ?? fallbackSize
        let size = CGSize(width: max(referenceSize.width, 1), height: max(referenceSize.height, 1))
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return PDFPage(image: image)
    }

    private func makeImportPages(from url: URL) -> [PDFPage] {
        if let source = PDFDocument(url: url) {
            return (0 ..< source.pageCount).compactMap { index in
                guard let page = source.page(at: index) else { return nil }
                return page.copy() as? PDFPage
            }
        }

        guard let image = NSImage(contentsOf: url),
              let page = PDFPage(image: image)
        else {
            return []
        }
        return [page]
    }

    func saveAs() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (currentURL?.lastPathComponent ?? "PDFQuickFix.pdf")
        if panel.runModal() == .OK, let url = panel.url {
            if writeDocument(doc, to: url) {
                setDocument(document ?? doc, url: url)
                sourceURL = url
                pushLog("Saved as \(url.lastPathComponent)")
            } else {
                pushLog("Failed to save to \(url.path)")
            }
        }
    }

    func saveDocument() {
        guard let doc = document else { return }
        guard let url = sourceURL ?? currentURL ?? doc.documentURL else {
            saveAs()
            return
        }

        if writeDocument(doc, to: url) {
            currentURL = url
            sourceURL = url
            pushLog("Saved \(url.lastPathComponent)")
        } else {
            pushLog("Save failed: \(url.lastPathComponent)")
        }
    }

    private func writeDocument(_ doc: PDFDocument, to url: URL) -> Bool {
        guard PDFOps.containsReplacementTextAnnotations(in: doc) else {
            let detachedHelper = detachSelectionHelperForPersistence()
            defer { restoreSelectionHelperAfterPersistence(detachedHelper) }
            return doc.write(to: url)
        }
        guard !doc.isEncrypted else {
            pushLog("Save blocked: export an encrypted copy after replacing text in a protected PDF.")
            return false
        }

        let detachedHelper = detachSelectionHelperForPersistence()
        do {
            let data = try PDFOps.flattenedData(document: doc)
            try data.write(to: url, options: .atomic)
            guard let flattened = PDFDocument(data: data) else {
                throw PDFOpsError.saveFailed
            }
            document = flattened
            pdfView?.document = flattened
            currentSelectionText = nil
            selectedAnnotation = nil
            selectedPageIDs = []
            clearEditUndoStacks()
            refreshPages()
            refreshOutline()
            refreshAnnotations()
            return true
        } catch {
            restoreSelectionHelperAfterPersistence(detachedHelper)
            pushLog("Save failed: \(error.localizedDescription)")
            present(error)
            return false
        }
    }

    func repairAndSaveAs() {
        guard let url = currentURL else { return }

        isDocumentLoading = true
        loadingStatus = "Normalizing document..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let service = PDFRepairService()
                let repairedURL = try service.repairForExport(inputURL: url)

                DispatchQueue.main.async {
                    self.isDocumentLoading = false
                    self.loadingStatus = nil

                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.pdf]
                    panel.nameFieldStringValue = (url.deletingPathExtension().lastPathComponent) + "-repaired.pdf"

                    if panel.runModal() == .OK, let destination = panel.url {
                        do {
                            if FileManager.default.fileExists(atPath: destination.path) {
                                try FileManager.default.removeItem(at: destination)
                            }
                            try FileManager.default.moveItem(at: repairedURL, to: destination)
                            self.pushLog("Saved repaired document to \(destination.lastPathComponent)")
                            NSWorkspace.shared.activateFileViewerSelecting([destination])
                        } catch {
                            self.pushLog("Failed to save repaired document: \(error.localizedDescription)")
                            self.present(error)
                        }
                    } else {
                        try? FileManager.default.removeItem(at: repairedURL)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isDocumentLoading = false
                    self.loadingStatus = nil
                    self.pushLog("Repair failed: \(error.localizedDescription)")
                    self.present(error)
                }
            }
        }
    }

    func exportToImages(format: NSBitmapImageRep.FileType) {
        guard document != nil else {
            pushLog("Export failed: couldn't read current document state")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder to save images"
        panel.directoryURL = currentURL?.deletingLastPathComponent()

        if panel.runModal() == .OK, let outputDir = panel.url {
            let snapshot: Data
            do {
                snapshot = try imageExportSnapshotData()
            } catch {
                pushLog("Export failed: \(error.localizedDescription)")
                present(error)
                return
            }

            let fileExtension = switch format {
            case .jpeg: "jpg"
            case .png: "png"
            case .tiff: "tiff"
            default: "img"
            }

            isDocumentLoading = true
            loadingStatus = "Exporting images..."

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer {
                    DispatchQueue.main.async {
                        self?.isDocumentLoading = false
                        self?.loadingStatus = nil
                    }
                }

                // Create a new PDFDocument instance for background processing
                guard let backgroundDoc = PDFDocument(data: snapshot) else {
                    DispatchQueue.main.async {
                        self?.pushLog("Export failed: couldn't read current document state")
                    }
                    return
                }

                for i in 0 ..< backgroundDoc.pageCount {
                    guard let page = backgroundDoc.page(at: i) else { continue }
                    let pageRect = page.bounds(for: .mediaBox)
                    let image = page.thumbnail(of: pageRect.size, for: .mediaBox)

                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let data = bitmap.representation(using: format, properties: [:])
                    {
                        let filename = "Page_\(i + 1).\(fileExtension)"
                        let fileURL = outputDir.appendingPathComponent(filename)
                        try? data.write(to: fileURL)
                    }
                }

                DispatchQueue.main.async {
                    self?.pushLog("Exported images to \(outputDir.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([outputDir])
                }
            }
        }
    }

    func imageExportSnapshotData() throws -> Data {
        guard let document else { throw PDFOpsError.missingDocument }
        let snapshot = try PDFOps.privacyPreservingSnapshot(document: document)
        guard let data = snapshot.dataRepresentation() else {
            throw PDFOpsError.saveFailed
        }
        return data
    }

    var hasPrintableDocument: Bool {
        document != nil
    }

    func printDocument() {
        _ = DocumentPrintService.print(document: document,
                                       jobTitle: document?.documentURL?.lastPathComponent ?? "PDFQuickFix",
                                       source: "studio")
    }

    func exportToText() {
        guard let doc = document else {
            pushLog("Export failed: couldn't read current document state")
            return
        }
        guard !PDFOps.containsReplacementTextAnnotations(in: doc) else {
            pushLog("Export blocked: Text export is blocked after Replace Text or Redact Text because the original text layer may still be extractable. Export a sanitized or flattened PDF copy instead.")
            return
        }
        guard !doc.isEncrypted else {
            pushLog("Export blocked: Text export is blocked for encrypted PDFs. Export a flattened or sanitized copy first.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (currentURL?.deletingPathExtension().lastPathComponent ?? "Document") + ".txt"

        if panel.runModal() == .OK, let url = panel.url {
            isDocumentLoading = true
            loadingStatus = "Exporting text..."
            guard let snapshotData = doc.dataRepresentation() else {
                isDocumentLoading = false
                loadingStatus = nil
                pushLog("Export failed: couldn't snapshot current document state")
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer {
                    DispatchQueue.main.async {
                        self?.isDocumentLoading = false
                        self?.loadingStatus = nil
                    }
                }

                do {
                    guard let snapshot = PDFDocument(data: snapshotData) else {
                        throw PDFOpsError.missingDocument
                    }
                    let fullText = try PDFOps.extractTextForExport(document: snapshot)
                    try fullText.write(to: url, atomically: true, encoding: .utf8)

                    DispatchQueue.main.async {
                        self?.pushLog("Exported text to \(url.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.pushLog("Export failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func exportOptimized() {
        guard let doc = document else {
            pushLog("Export failed: no document is loaded")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (currentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-optimized.pdf"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshotData: Data
        do {
            let snapshot = try PDFOps.privacyPreservingSnapshot(document: doc)
            guard let data = snapshot.dataRepresentation() else {
                throw PDFOpsError.saveFailed
            }
            snapshotData = data
        } catch {
            pushLog("Optimize export failed: \(error.localizedDescription)")
            present(error)
            return
        }

        pushLog("Optimizing \(url.lastPathComponent)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let snapshot = PDFDocument(data: snapshotData),
                      let optimizedData = PDFOps.optimize(document: snapshot)
                else {
                    throw PDFOpsError.saveFailed
                }
                try optimizedData.write(to: url, options: .atomic)
                Task { @MainActor [weak self] in
                    self?.pushLog("Exported optimized copy to \(url.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.pushLog("Optimize export failed: \(error.localizedDescription)")
                    self?.present(error)
                }
            }
        }
    }

    func exportMetadataCleaned() {
        guard let doc = document else {
            pushLog("Export failed: no document is loaded")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (currentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-metadata-clean.pdf"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let cleanedData = try PDFOps.metadataCleanedData(document: doc, sourceURL: currentURL)
                try cleanedData.write(to: url, options: .atomic)
                pushLog("Exported metadata-clean copy to \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                pushLog("Metadata-clean export failed: \(error.localizedDescription)")
                present(error)
            }
        }
    }

    func exportFlattened() {
        guard let doc = document else {
            pushLog("Export failed: no document is loaded")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (currentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-flattened.pdf"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let flattenedData = try PDFOps.flattenedData(document: doc)
                try flattenedData.write(to: url, options: .atomic)
                pushLog("Exported flattened copy to \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                pushLog("Flattened export failed: \(error.localizedDescription)")
                present(error)
            }
        }
    }

    func exportEncrypted() {
        guard let doc = document else {
            pushLog("Export failed: no document is loaded")
            return
        }
        guard let options = PDFEncryptionExport.requestOptions() else { return }

        do {
            if let url = try PDFEncryptionExport.writeEncryptedCopy(
                document: doc,
                sourceURL: currentURL ?? doc.documentURL,
                options: options
            ) {
                pushLog("Exported encrypted copy to \(url.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            pushLog("Encrypted export failed: \(error.localizedDescription)")
            present(error)
        }
    }

    func exportSanitized() {
        guard let doc = document else { return }
        // We need a snapshot because sanitization (especially vector/data rebuild)
        // works best on a stable data representation or copy.
        // But for sanitization options that just change metadata, we can use a copy.
        // Let's use dataRepresentation to be safe and consistent with other exports.
        let snapshotDoc: PDFDocument
        do {
            snapshotDoc = try PDFOps.privacyPreservingSnapshot(document: doc)
        } catch {
            pushLog("Export failed: couldn't read current document state")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (currentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-sanitized.pdf"

        // Build accessory view with NSStackView for robust layout
        let label = NSTextField(labelWithString: "Sanitization Profile:")
        label.setContentHuggingPriority(.required, for: .vertical)

        let profileSelector = NSPopUpButton(frame: .zero, pullsDown: false)
        profileSelector.addItems(withTitles: [
            "Privacy Clean (Rasterize, No Metadata)",
            "Light Clean (Searchable, No Metadata)",
            "Keep Editable (Forms OK, No Metadata)",
        ])

        // Map index to profile
        let profiles: [SanitizeProfile] = [.privacyClean, .lightClean, .keepEditable]

        // Preselect based on user's default profile
        let defaultProfile = SanitizeDefaults.shared.defaultProfile
        let initialIndex = profiles.firstIndex(of: defaultProfile) ?? 0
        profileSelector.selectItem(at: initialIndex)

        // "Set as default" checkbox
        let checkbox = NSButton(checkboxWithTitle: "Set as default", target: nil, action: nil)
        checkbox.state = .on

        let stackView = NSStackView(views: [label, profileSelector, checkbox])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Wrap in container for proper sizing
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 90))
        accessoryView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: accessoryView.bottomAnchor),
        ])
        panel.accessoryView = accessoryView

        if panel.runModal() == .OK, let destination = panel.url {
            let selectedIndex = profileSelector.indexOfSelectedItem
            guard selectedIndex >= 0, selectedIndex < profiles.count else { return }
            let profile = profiles[selectedIndex]
            let options = PDFDocumentSanitizer.Options.from(profile: profile)
            let sendableSnapshot = SendablePDFDocument(document: snapshotDoc)

            // Persist default if checkbox is on
            if checkbox.state == .on {
                SanitizeDefaults.shared.defaultProfile = profile
            }

            isDocumentLoading = true
            loadingStatus = "Sanitizing..."

            let sourceURL = currentURL
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer {
                    DispatchQueue.main.async {
                        self?.isDocumentLoading = false
                        self?.loadingStatus = nil
                    }
                }

                do {
                    // Use the snapshotDoc we prepared
                    let processed = try PDFDocumentSanitizer.sanitize(document: sendableSnapshot.document,
                                                                      sourceURL: sourceURL,
                                                                      options: options)
                    { processed, total in
                        DispatchQueue.main.async {
                            self?.loadingStatus = "Sanitizing \(processed)/\(total)"
                        }
                    } shouldCancel: {
                        // Simplify cancellation for now
                        false
                    }

                    guard processed.write(to: destination) else {
                        throw PDFOpsError.saveFailed
                    }

                    DispatchQueue.main.async {
                        self?.pushLog("Exported sanitized (\(profile.rawValue)) to \(destination.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.pushLog("Sanitization failed: \(error.localizedDescription)")
                        self?.present(error)
                    }
                }
            }
        }
    }

    func exportSelectedPages() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Selection.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try selectedPagesExportData()
                try data.write(to: url, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                pushLog("Exported \(selectedPageIDs.count) page(s) to \(url.lastPathComponent)")
            } catch {
                pushLog("Selected-page export failed: \(error.localizedDescription)")
                present(error)
            }
        }
    }

    func selectedPagesExportData() throws -> Data {
        guard let doc = document else { throw PDFOpsError.missingDocument }
        let targets = selectedPageIDs.sorted()
        guard !targets.isEmpty else {
            throw PDFOpsError.invalidInput("Select at least one page to export.")
        }

        let exportDocument = PDFDocument()
        for (offset, index) in targets.enumerated() {
            if let page = doc.page(at: index),
               let copy = page.copy() as? PDFPage
            {
                exportDocument.insert(copy, at: offset)
            }
        }

        let safeDocument = try PDFOps.privacyPreservingDocumentForExport(exportDocument)
        guard let data = safeDocument.dataRepresentation() else {
            throw PDFOpsError.saveFailed
        }
        return data
    }

    func renameOutline(_ row: OutlineRow, title: String) {
        let sanitized = PDFStringNormalizer.normalizedNonEmpty(title, context: "outline rename") ?? "Untitled"
        let oldLabel = row.outline.label
        row.outline.label = sanitized
        registerOutlineRename(row.outline, oldLabel: oldLabel, newLabel: sanitized, actionName: "Rename Bookmark")
        refreshOutline()
        pushLog("Renamed bookmark to \"\(sanitized)\"")
    }

    func deleteOutline(_ row: OutlineRow) {
        guard let doc = document,
              let parent = row.outline.parent,
              let index = outlineChildIndex(row.outline, in: parent) else { return }
        registerOutlineRemoval(row.outline,
                               parent: parent,
                               document: doc,
                               index: index,
                               createdRoot: false,
                               actionName: "Delete Bookmark")
        row.outline.removeFromParent()
        refreshOutline()
        pushLog("Removed bookmark")
    }

    func addOutline(title: String) {
        guard let doc = document else { return }
        guard let page = pdfView?.currentPage ?? doc.page(at: 0) else { return }
        let sanitizedTitle = PDFStringNormalizer.normalizedNonEmpty(title, context: "new outline title") ?? "Untitled"
        let destination = PDFDestination(page: page,
                                         at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY))
        let outline = PDFOutline()
        outline.label = sanitizedTitle
        outline.destination = destination

        let parent: PDFOutline
        let insertionIndex: Int
        let createdRoot: Bool
        if let root = doc.outlineRoot {
            parent = root
            insertionIndex = root.numberOfChildren
            createdRoot = false
            root.insertChild(outline, at: root.numberOfChildren)
        } else {
            let root = PDFOutline()
            let rootLabel = PDFStringNormalizer.normalizedNonEmpty(doc.documentURL?.lastPathComponent,
                                                                   context: "outline root title") ?? "Bookmarks"
            root.label = rootLabel
            parent = root
            insertionIndex = 0
            createdRoot = true
            root.insertChild(outline, at: 0)
            doc.outlineRoot = root
        }
        registerOutlineInsertion(outline,
                                 parent: parent,
                                 document: doc,
                                 index: insertionIndex,
                                 createdRoot: createdRoot,
                                 actionName: "Add Bookmark")
        refreshOutline(preserving: [outline])
        pushLog("Added bookmark \"\(outline.label ?? "Untitled")\"")
    }

    func metadataDraft() -> DocumentMetadataDraft {
        let attributes = document?.documentAttributes
        return DocumentMetadataDraft(
            title: metadataString(for: PDFDocumentAttribute.titleAttribute, in: attributes),
            author: metadataString(for: PDFDocumentAttribute.authorAttribute, in: attributes),
            subject: metadataString(for: PDFDocumentAttribute.subjectAttribute, in: attributes),
            keywords: metadataKeywords(in: attributes),
            creator: metadataString(for: PDFDocumentAttribute.creatorAttribute, in: attributes),
            producer: metadataString(for: PDFDocumentAttribute.producerAttribute, in: attributes)
        )
    }

    func applyMetadata(_ draft: DocumentMetadataDraft) {
        guard let doc = document else { return }
        let oldAttributes = doc.documentAttributes
        var attributes = doc.documentAttributes ?? [:]
        setMetadataValue(draft.title, for: PDFDocumentAttribute.titleAttribute, in: &attributes)
        setMetadataValue(draft.author, for: PDFDocumentAttribute.authorAttribute, in: &attributes)
        setMetadataValue(draft.subject, for: PDFDocumentAttribute.subjectAttribute, in: &attributes)
        setMetadataKeywords(draft.keywords, in: &attributes)
        setMetadataValue(draft.creator, for: PDFDocumentAttribute.creatorAttribute, in: &attributes)
        setMetadataValue(draft.producer, for: PDFDocumentAttribute.producerAttribute, in: &attributes)
        doc.documentAttributes = attributes
        registerMetadataChange(document: doc,
                               oldAttributes: oldAttributes,
                               newAttributes: attributes,
                               actionName: "Edit Metadata")
        pushLog("Updated document metadata")
    }

    func clearMetadata() {
        guard let doc = document else { return }
        let oldAttributes = doc.documentAttributes
        doc.documentAttributes = [:]
        registerMetadataChange(document: doc,
                               oldAttributes: oldAttributes,
                               newAttributes: [:],
                               actionName: "Clear Metadata")
        pushLog("Cleared document metadata")
    }

    private func metadataString(for key: PDFDocumentAttribute, in attributes: [AnyHashable: Any]?) -> String {
        guard let value = metadataValue(for: key, in: attributes) else { return "" }
        if let string = value as? String { return string }
        if let string = value as? NSString { return string as String }
        return String(describing: value)
    }

    private func metadataKeywords(in attributes: [AnyHashable: Any]?) -> String {
        guard let value = metadataValue(for: PDFDocumentAttribute.keywordsAttribute, in: attributes) else { return "" }
        if let values = value as? [String] {
            return values.joined(separator: ", ")
        }
        if let values = value as? [Any] {
            return values.map { String(describing: $0) }.joined(separator: ", ")
        }
        return String(describing: value)
    }

    private func metadataValue(for key: PDFDocumentAttribute, in attributes: [AnyHashable: Any]?) -> Any? {
        attributes?[key] ?? attributes?[key.rawValue]
    }

    private func setMetadataValue(_ value: String,
                                  for key: PDFDocumentAttribute,
                                  in attributes: inout [AnyHashable: Any])
    {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        attributes.removeValue(forKey: key.rawValue)
        if trimmed.isEmpty {
            attributes.removeValue(forKey: key)
        } else {
            attributes[key] = trimmed
        }
    }

    private func setMetadataKeywords(_ value: String, in attributes: inout [AnyHashable: Any]) {
        let keywords = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        attributes.removeValue(forKey: PDFDocumentAttribute.keywordsAttribute.rawValue)
        if keywords.isEmpty {
            attributes.removeValue(forKey: PDFDocumentAttribute.keywordsAttribute)
        } else {
            attributes[PDFDocumentAttribute.keywordsAttribute] = keywords
        }
    }

    func focus(annotation row: AnnotationRow) {
        guard let page = row.annotation.page else { return }
        let bounds = row.annotation.bounds
        let destination = PDFDestination(page: page,
                                         at: CGPoint(x: bounds.midX, y: bounds.midY))
        pdfView?.go(to: destination)
    }

    func delete(annotation row: AnnotationRow) {
        guard let page = row.annotation.page else { return }
        registerAnnotationRemoval(row.annotation, on: page, actionName: "Delete Annotation")
        clearSelectedAnnotationIfNeeded(row.annotation)
        page.removeAnnotation(row.annotation)
        refreshAnnotations()
        pushLog("Removed annotation")
    }

    func addFormField(kind: FormFieldKind, name: String, rect: CGRect, options: [String] = []) {
        guard let doc = document else { return }
        guard let page = pdfView?.currentPage ?? doc.page(at: 0) else { return }
        let requestedName = PDFStringNormalizer.normalize(name, context: "form field name") ?? ""
        let fieldName = requestedName.isEmpty ? kind.rawValue : requestedName
        let normalizedOptions = options.compactMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return PDFStringNormalizer.normalize(trimmed, context: "form choice option")
        }.filter { !$0.isEmpty }
        let annotation: PDFAnnotation
        switch kind {
        case .text:
            annotation = PDFFormBuilder.makeTextField(name: fieldName, rect: rect)
            annotation.font = NSFont.systemFont(ofSize: 12)
            annotation.widgetStringValue = ""
            annotation.widgetDefaultStringValue = ""
        case .checkbox:
            annotation = PDFFormBuilder.makeCheckbox(name: fieldName, rect: rect)
        case .radio:
            annotation = PDFFormBuilder.makeRadio(name: fieldName, rect: rect)
            annotation.buttonWidgetStateString = "Off"
        case .dropdown:
            annotation = PDFFormBuilder.makeChoice(name: fieldName,
                                                   rect: rect,
                                                   choices: normalizedOptions.isEmpty ? ["Option"] : normalizedOptions,
                                                   isList: false)
        case .list:
            annotation = PDFFormBuilder.makeChoice(name: fieldName,
                                                   rect: rect,
                                                   choices: normalizedOptions.isEmpty ? ["Option"] : normalizedOptions,
                                                   isList: true)
        case .signature:
            annotation = PDFFormBuilder.makeSignature(name: fieldName, rect: rect)
            annotation.backgroundColor = NSColor.clear
        }
        let border = annotation.border ?? {
            let newBorder = PDFBorder()
            newBorder.lineWidth = 1
            return newBorder
        }()
        border.lineWidth = 1
        if kind == .signature {
            border.style = .dashed
            border.dashPattern = [4, 2]
        } else {
            border.style = .solid
            border.dashPattern = nil
        }
        annotation.border = border
        page.addAnnotation(annotation)
        registerAnnotationAddition(annotation, actionName: "Add Form Field")
        refreshAnnotations()
        pushLog("Added \(kind.rawValue)")
    }

    func addSignatureStamp(image: NSImage, width: CGFloat = 180) {
        guard let doc = document else { return }
        guard let page = pdfView?.currentPage ?? doc.page(at: 0) else { return }
        let pageBounds = page.bounds(for: .cropBox)
        let safeWidth = max(80, min(width, pageBounds.width * 0.8))
        let aspectRatio = image.size.width > 0 ? image.size.height / image.size.width : 0.35
        let safeHeight = max(28, safeWidth * max(aspectRatio, 0.15))
        let rect = CGRect(x: pageBounds.midX - safeWidth / 2,
                          y: pageBounds.midY - safeHeight / 2,
                          width: safeWidth,
                          height: safeHeight)
        let annotation = ImageStampAnnotation(bounds: rect, image: image)
        annotation.contents = "Signature"
        annotation.userName = "PDFQuickFix Signature"
        page.addAnnotation(annotation)
        registerAnnotationAddition(annotation, actionName: "Add Signature")
        refreshAnnotations()
        pushLog("Added signature stamp")
    }

    func applyWatermark(text: String,
                        fontSize: CGFloat,
                        color: NSColor,
                        opacity: CGFloat,
                        rotation: CGFloat,
                        position: WatermarkPosition,
                        margin: CGFloat) throws
    {
        guard let document else { throw PDFOpsError.missingDocument }
        let additions = newAnnotations {
            PDFOps.applyWatermark(document: document,
                                  text: text,
                                  fontSize: fontSize,
                                  color: color,
                                  opacity: opacity,
                                  rotation: rotation,
                                  position: position,
                                  margin: margin)
        }
        registerAnnotationAdditions(additions, actionName: "Apply Watermark")
        refreshAnnotations()
        pushLog("Watermark applied")
    }

    func applyHeaderFooter(header: String,
                           footer: String,
                           margin: CGFloat,
                           fontSize: CGFloat) throws
    {
        guard let document else { throw PDFOpsError.missingDocument }
        let additions = newAnnotations {
            PDFOps.applyHeaderFooter(document: document,
                                     header: header,
                                     footer: footer,
                                     margin: margin,
                                     fontSize: fontSize)
        }
        registerAnnotationAdditions(additions, actionName: "Apply Header/Footer")
        refreshAnnotations()
        pushLog("Header/Footer applied")
    }

    func applyBatesNumbers(prefix: String,
                           start: Int,
                           digits: Int,
                           placement: BatesPlacement,
                           margin: CGFloat,
                           fontSize: CGFloat) throws
    {
        guard let document else { throw PDFOpsError.missingDocument }
        let additions = newAnnotations {
            PDFOps.applyBatesNumbers(document: document,
                                     prefix: prefix,
                                     start: start,
                                     digits: digits,
                                     placement: placement,
                                     margin: margin,
                                     fontSize: fontSize)
        }
        registerAnnotationAdditions(additions, actionName: "Apply Bates Numbers")
        refreshAnnotations()
        pushLog("Bates numbers applied")
    }

    func crop(inset: CGFloat, target: CropTarget) throws {
        guard let document else { throw PDFOpsError.missingDocument }
        let before = (0 ..< document.pageCount).compactMap { index -> (PDFPage, CGRect, CGRect)? in
            guard let page = document.page(at: index), target.contains(index: index) else { return nil }
            return (page, page.bounds(for: .mediaBox), page.bounds(for: .cropBox))
        }
        PDFOps.crop(document: document, inset: inset, target: target)
        let changes = before.compactMap { page, oldMediaBox, oldCropBox -> PageBoundsChange? in
            let newMediaBox = page.bounds(for: .mediaBox)
            let newCropBox = page.bounds(for: .cropBox)
            guard newMediaBox != oldMediaBox || newCropBox != oldCropBox else { return nil }
            return PageBoundsChange(page: page,
                                    oldMediaBox: oldMediaBox,
                                    oldCropBox: oldCropBox,
                                    newMediaBox: newMediaBox,
                                    newCropBox: newCropBox)
        }
        registerPageBoundsChange(changes, actionName: "Crop Pages")
        refreshPages()
        pushLog("Cropped pages")
    }

    func optimize() throws -> Data {
        guard let document,
              let data = PDFOps.optimize(document: document)
        else {
            throw PDFOpsError.missingDocument
        }
        pushLog("Optimized document (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
        return data
    }

    private func scheduleValidation(for url: URL, pageLimit: Int?, mode: ValidationMode) {
        validationRunner.cancelValidation()
        validationMode = mode
        isFullValidationRunning = (mode == .full)
        updateValidationStatus(processed: 0, total: pageLimit ?? (document?.pageCount ?? 0))
        validationRunner.validateDocument(at: url,
                                          pageLimit: pageLimit,
                                          progress: { [weak self] processed, total in
                                              guard let self, currentURL == url else { return }
                                              updateValidationStatus(processed: processed, total: total)
                                          },
                                          completion: { [weak self] result in
                                              guard let self, currentURL == url else { return }
                                              validationMode = .idle
                                              isFullValidationRunning = false
                                              validationStatus = nil
                                              switch result {
                                              case let .success(sanitized):
                                                  pushLog("Validated \(sanitized.pageCount) pages")
                                              case let .failure(error):
                                                  if case PDFDocumentSanitizerError.cancelled = error { return }
                                                  pushLog("⚠️ \(error.localizedDescription)")
                                                  present(error)
                                              }
                                          })
    }

    private func updateValidationStatus(processed: Int, total: Int) {
        guard validationMode != .idle else {
            validationStatus = nil
            return
        }
        let prefix = (validationMode == .quick) ? "Quick check" : "Validating"
        if total > 0 {
            validationStatus = "\(prefix) \(min(processed, total))/\(total)"
        } else {
            validationStatus = prefix
        }
    }

    private func applyPDFViewConfiguration() {
        guard let pdfView else { return }
        pdfView.applyPerformanceTuning(isLargeDocument: isLargeDocument,
                                       desiredDisplayMode: .singlePageContinuous,
                                       resetScale: true)
    }

    private func resetThumbnailState() {
        thumbnailCache.removeAllObjects()
        inflightThumbnails.removeAll()
    }

    #if DEBUG
        var debugInfo: StudioDebugInfo {
            let pages = document?.pageCount ?? 0
            let isLarge = isLargeDocument
            let isMassive = DocumentProfile.from(pageCount: pages).isMassive
            let render = renderService.debugInfo()
            return StudioDebugInfo(pageCount: pages,
                                   isLargeDocument: isLarge,
                                   isMassiveDocument: isMassive,
                                   renderQueueOps: render.queueOperationCount,
                                   renderTrackedOps: render.trackedOperationsCount)
        }
    #endif

    func ensureThumbnail(for index: Int) {
        guard let document else { return }
        guard index >= 0 && index < document.pageCount else { return }
        let sp = PerfLog.begin("StudioEnsureThumbnail")
        defer { PerfLog.end("StudioEnsureThumbnail", sp) }
        let key = NSNumber(value: index)
        if let cached = thumbnailCache.object(forKey: key) {
            updateSnapshot(at: index, thumbnail: cached)
            return
        }

        inflightLock.lock()
        if inflightThumbnails.contains(index) {
            inflightLock.unlock()
            return
        }
        inflightThumbnails.insert(index)
        inflightLock.unlock()

        let doc = document
        let pageCount = doc.pageCount
        guard index >= 0, index < pageCount else {
            inflightLock.lock()
            inflightThumbnails.remove(index)
            inflightLock.unlock()
            return
        }

        let thumbSize = isMassiveDocument ? massiveThumbnailTargetSize : snapshotTargetSize

        // For massive documents, use the streaming loader for faster thumbnail rendering
        if isMassiveDocument, streamingLoader.isOpen {
            let loader = streamingLoader
            thumbnailQueue.async { [weak self, loader] in
                let image = loader.renderThumbnail(at: index, size: thumbSize)

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    inflightThumbnails.remove(index)

                    guard let image else { return }
                    thumbnailCache.setObject(image, forKey: key)
                    updateSnapshot(at: index, thumbnail: image)
                }
            }
            return
        }

        // Standard path for non-massive documents
        let docURL = doc.documentURL
        let docData: Data? = if !isMassiveDocument {
            doc.dataRepresentation()
        } else {
            nil
        }

        renderService.thumbnail(pageIndex: index,
                                targetSize: thumbSize,
                                documentURL: docURL,
                                documentData: docData,
                                priority: .high)
        { [weak self] image in
            guard let self else { return }
            inflightLock.lock()
            inflightThumbnails.remove(index)
            inflightLock.unlock()

            guard let image else { return }
            thumbnailCache.setObject(image, forKey: key)
            updateSnapshot(at: index, thumbnail: image)
        }
    }

    func prefetchThumbnails(around centerIndex: Int,
                            window: Int = 2,
                            farWindow: Int = 6)
    {
        guard let doc = document else { return }
        let sp = PerfLog.begin("StudioPrefetch")
        defer { PerfLog.end("StudioPrefetch", sp) }
        guard !isMassiveDocument else { return }
        let count = doc.pageCount
        guard count > 0 else { return }

        let targetSize = snapshotTargetSize
        let mediaWidth = max(targetSize.width, 1)
        let bucket = Int(mediaWidth.rounded(.toNearestOrEven))

        func makeRequest(_ idx: Int) -> PDFRenderRequest? {
            guard idx >= 0, idx < count else { return nil }
            return PDFRenderRequest(kind: .thumbnail,
                                    pageIndex: idx,
                                    scaleBucket: bucket,
                                    size: targetSize)
        }

        let docURL = doc.documentURL
        let docData: Data?
        docData = isMassiveDocument ? nil : doc.dataRepresentation()

        // Near window (±window) with high priority.
        for offset in -window ... window {
            let idx = centerIndex + offset
            guard let request = makeRequest(idx) else { continue }
            if thumbnailCache.object(forKey: NSNumber(value: idx)) != nil { continue }
            renderService.image(for: request,
                                documentURL: docURL,
                                documentData: docData,
                                priority: .veryHigh)
            { [weak self] image in
                guard let self, let image else { return }
                let key = NSNumber(value: idx)
                thumbnailCache.setObject(image, forKey: key)
                updateSnapshot(at: idx, thumbnail: image)
            }
        }

        // Far window (±farWindow) with lower priority.
        for offset in -farWindow ... farWindow {
            if abs(offset) <= window { continue }
            let idx = centerIndex + offset
            guard let request = makeRequest(idx) else { continue }
            if thumbnailCache.object(forKey: NSNumber(value: idx)) != nil { continue }
            renderService.image(for: request,
                                documentURL: docURL,
                                documentData: docData,
                                priority: .low)
            { [weak self] image in
                guard let self, let image else { return }
                let key = NSNumber(value: idx)
                thumbnailCache.setObject(image, forKey: key)
                updateSnapshot(at: idx, thumbnail: image)
            }
        }
    }

    private func updateSnapshot(at index: Int, thumbnail: CGImage) {
        guard index >= 0, index < (virtualPageProvider.isVirtualized ? virtualPageProvider.totalCount : pageSnapshots.count) else { return }

        Task { [weak self] in
            guard let self else { return }
            await snapshotUpdateThrottle.run { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    // Use virtual provider if active
                    if self.virtualPageProvider.isVirtualized {
                        self.virtualPageProvider.updateThumbnail(at: index, thumbnail: thumbnail)
                        self.pageSnapshots = self.virtualPageProvider.visibleSnapshots
                        return
                    }

                    // Fallback to direct array update
                    guard index >= 0, index < self.pageSnapshots.count else { return }
                    var snapshots = self.pageSnapshots
                    let existing = snapshots[index]
                    if existing.thumbnail === thumbnail { return }
                    snapshots[index] = PageSnapshot(id: existing.id,
                                                    index: existing.index,
                                                    thumbnail: thumbnail,
                                                    label: existing.label)
                    self.pageSnapshots = snapshots
                }
            }
        }
    }

    private func currentDisplayedPageIndex() -> Int? {
        guard let view = pdfView, let doc = document, let current = view.currentPage else { return nil }
        let index = doc.index(for: current)
        return index >= 0 ? index : nil
    }

    func pushLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logMessages.append("[\(timestamp)] \(message)")
    }

    private func present(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "PDF açılamadı"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

private final class PageSnapshotRenderOperation: Operation {
    private let document: PDFDocument
    private let targetSize: CGSize
    private let chunkSize: Int = 8
    private let completion: ([PageSnapshot], Bool) -> Void

    init(document: PDFDocument,
         targetSize: CGSize,
         completion: @escaping ([PageSnapshot], Bool) -> Void)
    {
        self.document = document
        self.targetSize = targetSize
        self.completion = completion
    }

    override func main() {
        if isCancelled { return }
        guard let cgDocument = Self.makeCGDocument(from: document) else {
            let fallback = Self.makeSnapshotsUsingPDFKit(document: document, targetSize: targetSize)
            DispatchQueue.main.async { [fallback] in
                self.completion(fallback, true)
            }
            return
        }

        let pageCount = cgDocument.numberOfPages
        if pageCount == 0 {
            DispatchQueue.main.async {
                self.completion([], true)
            }
            return
        }

        var snapshots: [PageSnapshot] = []
        snapshots.reserveCapacity(pageCount)

        for index in 0 ..< pageCount {
            if isCancelled { return }
            guard let page = cgDocument.page(at: index + 1),
                  let image = Self.renderThumbnail(for: page, targetSize: targetSize) else { continue }
            snapshots.append(PageSnapshot(id: index,
                                          index: index,
                                          thumbnail: image,
                                          label: "Page \(index + 1)"))
            if isCancelled { return }
            if index % chunkSize == chunkSize - 1 || index == pageCount - 1 {
                let snapshotCopy = snapshots
                let isFinal = index == pageCount - 1
                DispatchQueue.main.async { [snapshotCopy, isFinal] in
                    self.completion(snapshotCopy, isFinal)
                }
            }
        }
    }

    private static func renderThumbnail(for page: CGPDFPage, targetSize: CGSize) -> CGImage? {
        let mediaBox = page.getBoxRect(.mediaBox)
        let safeWidth = max(mediaBox.width, 1)
        let safeHeight = max(mediaBox.height, 1)
        let scale = min(targetSize.width / safeWidth, targetSize.height / safeHeight, 1)
        let width = max(Int(safeWidth * scale), 1)
        let height = max(Int(safeHeight * scale), 1)

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: mediaBox.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.drawPDFPage(page)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private static func makeCGDocument(from document: PDFDocument) -> CGPDFDocument? {
        if let url = document.documentURL,
           let provider = CGDataProvider(url: url as CFURL),
           let cgDoc = CGPDFDocument(provider)
        {
            return cgDoc
        }
        if let data = document.dataRepresentation(),
           let provider = CGDataProvider(data: data as CFData)
        {
            return CGPDFDocument(provider)
        }
        return nil
    }

    private static func makeSnapshotsUsingPDFKit(document: PDFDocument, targetSize: CGSize) -> [PageSnapshot] {
        var items: [PageSnapshot] = []
        items.reserveCapacity(document.pageCount)
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let nsImage = page.thumbnail(of: NSSize(width: targetSize.width, height: targetSize.height), for: .mediaBox)
            guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            items.append(PageSnapshot(id: index,
                                      index: index,
                                      thumbnail: cgImage,
                                      label: "Page \(index + 1)"))
        }
        return items
    }
}

extension PageSnapshotRenderOperation: @unchecked Sendable {}

class SelectionAnnotation: PDFAnnotation {
    override func draw(with _: PDFDisplayBox, in context: CGContext) {
        // Do NOT call super.draw to avoid default appearance (like the X box)

        context.saveGState()

        // Draw border
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.0)

        let rect = bounds
        context.stroke(rect)

        // Handles
        let handleSize: CGFloat = 6.0
        // Corners
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX - handleSize, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY - handleSize),
            CGPoint(x: rect.maxX - handleSize, y: rect.maxY - handleSize),
        ]

        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.systemBlue.cgColor)

        for corner in corners {
            let handleRect = CGRect(origin: corner, size: CGSize(width: handleSize, height: handleSize))
            context.fill(handleRect)
            context.stroke(handleRect)
        }

        context.restoreGState()
    }
}

private extension Int {
    var normalizedRotation: Int {
        var value = self % 360
        if value < 0 { value += 360 }
        // PDFKit expects multiples of 90°
        if value % 90 != 0 {
            value = (value / 90) * 90
        }
        return value
    }
}

extension StudioController: FileExportable {}
extension StudioController: DocumentPrintable {}
extension StudioController: DocumentClosable {}
extension StudioController: DocumentHealthPresentable {}
extension StudioController: DocumentUndoable {}
extension StudioController: SelectedTextReplaceable {}
