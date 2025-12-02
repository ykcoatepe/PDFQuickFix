import Foundation
import SwiftUI
import AppKit
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import os.log
import PDFQuickFixKit

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

enum FormFieldKind: String, CaseIterable, Identifiable {
    case text = "Text Field"
    case checkbox = "Checkbox"
    case signature = "Signature"

    var id: String { rawValue }
}

struct StudioDebugInfo {
    let pageCount: Int
    let isLargeDocument: Bool
    let isMassiveDocument: Bool
    let renderQueueOps: Int
    let renderTrackedOps: Int
}

@MainActor
final class StudioController: NSObject, ObservableObject, PDFViewDelegate, PDFActionable, StudioToolSwitchable {
    @Published var document: PDFDocument?
    @Published var currentURL: URL?
    @Published var pageSnapshots: [PageSnapshot] = []
    @Published var selectedPageIDs: Set<Int> = []
    @Published var outlineRows: [OutlineRow] = []
    @Published var annotationRows: [AnnotationRow] = []
    @Published var logMessages: [String] = []
    @Published var validationStatus: String?
    @Published var isFullValidationRunning: Bool = false
    @Published var isThumbnailsLoading: Bool = false
    @Published var isDocumentLoading: Bool = false
    @Published var loadingStatus: String?
    @Published var isLargeDocument: Bool = false
    @Published var isMassiveDocument: Bool = false
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var selectedTool: StudioTool = .organize
    @Published var isRepaired: Bool = false
    
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
    weak var pdfView: PDFView?
    private let validationRunner = DocumentValidationRunner()
    private var snapshotGenerationID = UUID()
    private var snapshotOperation: PageSnapshotRenderOperation?
    private let renderService = PDFRenderService.shared
    private let snapshotUpdateThrottle = AsyncThrottle(.milliseconds(80))
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
    private let largeDocumentPageThreshold = DocumentValidationRunner.largeDocumentPageThreshold
    private enum ValidationMode { case idle, quick, full }
    private var validationMode: ValidationMode = .idle
    private var studioOpenSignpost: OSSignpostID?
    #if DEBUG
    private var studioOpenStart: Date?
    #endif



    deinit {
        NotificationCenter.default.removeObserver(self)
        validationRunner.cancelAll()
        snapshotOperation?.cancel()
    }

    func attach(pdfView: PDFView) {
        self.pdfView = pdfView
        pdfView.delegate = self
        pdfView.document = document
        applyPDFViewConfiguration()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handlePageChange(_:)), name: .PDFViewPageChanged, object: pdfView)
        
        if let doc = document,
           let page = pdfView.currentPage {
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
        prefetchThumbnails(around: index, window: 2, farWindow: 6)
    }

    func open(url: URL) {
        validationRunner.cancelValidation()
        validationRunner.cancelOpen()
        isDocumentLoading = true
        loadingStatus = "Opening \(url.lastPathComponent)…"
        studioOpenSignpost = PerfLog.begin("StudioOpen")
        #if DEBUG
        PerfMetrics.shared.reset()
        studioOpenStart = Date()
        #endif

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
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
                self.validationRunner.openDocument(at: finalURL,
                                              quickValidationPageLimit: 0,
                                              progress: { [weak self] processed, total in
                                                  guard let self = self else { return }
                                                  guard total > 0 else { return }
                                                  let clamped = min(processed, total)
                                                  self.loadingStatus = "Validating \(clamped)/\(total)"
                                              },
                                              completion: { [weak self] result in
                                                  guard let self = self else { return }
                                                  self.isDocumentLoading = false
                                                  self.loadingStatus = nil
                                                  switch result {
                                                  case .success(let doc):
                                                      self.finishOpen(document: doc, url: finalURL, isRepaired: repaired)
                                                  case .failure(let error):
                                                      self.handleOpenError(error)
                                                  }
                                              })
            }
        }
    }

    private func finishOpen(document newDocument: PDFDocument, url: URL, isRepaired: Bool = false) {
        let sp = PerfLog.begin("StudioFinishOpen")
        defer { PerfLog.end("StudioFinishOpen", sp) }
        document = newDocument
        currentURL = url
        let profile = DocumentProfile.from(pageCount: newDocument.pageCount)
        isLargeDocument = profile.isLarge
        isMassiveDocument = profile.isMassive
        resetThumbnailState()
        let isMassive = isMassiveDocument
        if isMassive {
            pdfView?.document = nil
            let count = newDocument.pageCount
            pageSnapshots = (0..<count).map { index in
                PageSnapshot(id: index,
                             index: index,
                             thumbnail: nil,
                             label: "Page \(index + 1)")
            }
            outlineRows = []
            annotationRows = []
            isThumbnailsLoading = false
            pushLog("Opened massive document (\(count) pages); Studio disabled for this file.")
        } else {
            pdfView?.document = newDocument
            applyPDFViewConfiguration()
            refreshAll()
            pushLog("Opened \(url.lastPathComponent)")
        }
        validationStatus = nil
        validationMode = .idle
        isFullValidationRunning = false
        self.isRepaired = isRepaired

        let shouldSkipAutoValidation = DocumentValidationRunner.shouldSkipQuickValidation(
            estimatedPages: nil,
            resolvedPageCount: newDocument.pageCount
        )
        if !isMassive && !shouldSkipAutoValidation {
            scheduleValidation(for: url, pageLimit: 10, mode: .quick)
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
        document = nil
        pdfView?.document = nil
        currentURL = nil
        isLargeDocument = false
        isMassiveDocument = false
        resetThumbnailState()
        validationStatus = nil
        validationMode = .idle
        isFullValidationRunning = false
        pageSnapshots = []
        outlineRows = []
        annotationRows = []
        selectedPageIDs = []
        isThumbnailsLoading = false
        pushLog("⚠️ \(error.localizedDescription)")
        present(error)
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
    
    private let selectionHandleSize: CGFloat = 6.0
    private var currentDragMode: DragMode = .none
    
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
        if let pdfView = pdfView, let page = pdfView.currentPage {
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
        guard let undoManager = pdfView?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { [weak self] controller in
            guard let self = self else { return }
            page.rotation = oldRotation
            self.notifyPageRotationChanged()
            self.registerRotationUndo(page: page, oldRotation: newRotation, newRotation: oldRotation)
        }
        undoManager.setActionName("Rotate Page")
    }
    
    func deleteSelectedAnnotation() {
        guard let annotation = selectedAnnotation, let page = annotation.page else { return }
        
        registerDelete(annotation: annotation, on: page)
        
        deselectAnnotation()
        page.removeAnnotation(annotation)
        refreshAnnotations()
        pushLog("Deleted annotation")
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
            case .move(let startPoint, let originalBounds):
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
                
            case .resize(let handle, let startPoint, let originalBounds):
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
    
    func handleMouseUp(in view: PDFView, with event: NSEvent) {
        guard !isMassiveDocument, let annotation = selectedAnnotation, let page = annotation.page else { return }
        
        if case .move(_, let originalBounds) = currentDragMode {
            let finalBounds = annotation.bounds
            if finalBounds != originalBounds {
                registerBoundsChange(annotation: annotation, oldBounds: originalBounds, newBounds: finalBounds)
            }
        } else if case .resize(_, _, let originalBounds) = currentDragMode {
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
            (.topRight, CGRect(origin: CGPoint(x: bounds.maxX - handleSize, y: bounds.maxY - handleSize), size: CGSize(width: handleSize, height: handleSize)))
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
        guard let undoManager = pdfView?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            annotation.bounds = oldBounds
            target.selectionHelperAnnotation?.bounds = oldBounds
            target.registerBoundsChange(annotation: annotation, oldBounds: newBounds, newBounds: oldBounds)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName("Move/Resize Annotation")
        }
    }

    private func registerDelete(annotation: PDFAnnotation, on page: PDFPage) {
        guard let undoManager = pdfView?.undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            page.addAnnotation(annotation)
            target.selectAnnotation(annotation)
            target.refreshAnnotations()
            target.registerDelete(annotation: annotation, on: page)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName("Delete Annotation")
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
                case .resize(let handle, _, _):
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
        guard let view = pdfView else { return }
        let viewRect = view.convert(rect, from: page)
        // Expand slightly to cover anti-aliasing/handles
        let expanded = viewRect.insetBy(dx: -10, dy: -10)
        view.setNeedsDisplay(expanded)
    }

    func setDocument(_ document: PDFDocument?, url: URL? = nil) {
        validationRunner.cancelValidation()
        self.document = document
        if let url {
            currentURL = url
        }
        isLargeDocument = (document?.pageCount ?? 0) > largeDocumentPageThreshold
        resetThumbnailState()
        pdfView?.document = document
        applyPDFViewConfiguration()
        refreshAll()
    }

    func runFullValidation() {
        guard let url = currentURL, document != nil, !isFullValidationRunning else { return }
        scheduleValidation(for: url, pageLimit: nil, mode: .full)
    }

    func refreshAll() {
        refreshPages()
        refreshOutline()
        refreshAnnotations()
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
        if DocumentProfile.from(pageCount: doc.pageCount).isMassive {
            let count = doc.pageCount
            pageSnapshots = (0..<count).map { index in
                PageSnapshot(id: index,
                             index: index,
                             thumbnail: nil,
                             label: "Page \(index + 1)")
            }
            isThumbnailsLoading = false
            snapshotOperation = nil
            return
        }

        let pageCount = doc.pageCount
        guard pageCount > 0 else {
            snapshotOperation = nil
            pageSnapshots = []
            isThumbnailsLoading = false
            return
        }

        if isLargeDocument {
            pageSnapshots = (0..<pageCount).map { index in
                PageSnapshot(id: index,
                             index: index,
                             thumbnail: thumbnailCache.object(forKey: NSNumber(value: index)),
                             label: "Page \(index + 1)")
            }
            isThumbnailsLoading = false
            return
        }

        isThumbnailsLoading = true

        let token = snapshotGenerationID
        let count = pageCount
        pageSnapshots = (0..<count).map { index in
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

    func refreshOutline() {
        guard let doc = document else {
            outlineRows = []
            return
        }
        if DocumentProfile.from(pageCount: doc.pageCount).isMassive {
            outlineRows = []
            pushLog("Outline disabled for massive documents (too many pages).")
            return
        }
        guard let root = doc.outlineRoot else {
            outlineRows = []
            return
        }

        var rows: [OutlineRow] = []
        func walk(item: PDFOutline, depth: Int) {
            rows.append(OutlineRow(outline: item, depth: depth))
            for childIndex in 0..<item.numberOfChildren {
                if let child = item.child(at: childIndex) {
                    walk(item: child, depth: depth + 1)
                }
            }
        }

        for childIndex in 0..<root.numberOfChildren {
            if let child = root.child(at: childIndex) {
                walk(item: child, depth: 0)
            }
        }
        outlineRows = rows
    }

    func refreshAnnotations() {
        guard let doc = document else {
            annotationRows = []
            return
        }
        guard !isLargeDocument else {
            annotationRows = []
            return
        }
        var rows: [AnnotationRow] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            for annotation in page.annotations {
                rows.append(AnnotationRow(annotation: annotation, pageIndex: index))
            }
        }
        annotationRows = rows
    }

    func goTo(page index: Int) {
        guard let page = document?.page(at: index) else { return }
        pdfView?.go(to: page)
    }

    func movePages(from source: IndexSet, to destination: Int) {
        guard let doc = document else { return }
        let pages = source.sorted().compactMap { doc.page(at: $0) }
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
        pushLog("Reordered \(pages.count) page(s)")
    }

    func movePage(at index: Int, to newIndex: Int) {
        guard let doc = document,
              let page = doc.page(at: index),
              index != newIndex else { return }
        doc.removePage(at: index)
        let destination = max(0, min(newIndex, doc.pageCount))
        doc.insert(page, at: destination)
        selectedPageIDs = Set([destination])
        refreshPages()
        pushLog("Moved page \(index + 1) to \(destination + 1)")
    }

    @discardableResult
    func deleteSelectedPages() -> Bool {
        guard let doc = document else { return false }
        let targets = selectedPageIDs.sorted(by: >)
        guard !targets.isEmpty else { return false }
        for index in targets {
            guard index < doc.pageCount else { continue }
            doc.removePage(at: index)
        }
        selectedPageIDs = []
        refreshPages()
        pushLog("Deleted \(targets.count) page(s)")
        return true
    }

    @discardableResult
    func duplicateSelectedPages() -> Bool {
        guard let doc = document else { return false }
        let targets = selectedPageIDs.sorted()
        guard !targets.isEmpty else { return false }
        for index in targets {
            guard let page = doc.page(at: index),
                  let clone = page.copy() as? PDFPage else { continue }
            doc.insert(clone, at: index + 1)
        }
        refreshPages()
        pushLog("Duplicated \(targets.count) page(s)")
        return true
    }

    func saveAs() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (currentURL?.lastPathComponent ?? "PDFQuickFix.pdf")
        if panel.runModal() == .OK, let url = panel.url {
            if doc.write(to: url) {
                setDocument(doc, url: url)
                pushLog("Saved as \(url.lastPathComponent)")
            } else {
                pushLog("Failed to save to \(url.path)")
            }
        }
    }

    func exportToImages(format: NSBitmapImageRep.FileType) {
        guard let doc = document, let snapshot = doc.dataRepresentation() else {
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
            let fileExtension: String
            switch format {
            case .jpeg: fileExtension = "jpg"
            case .png: fileExtension = "png"
            case .tiff: fileExtension = "tiff"
            default: fileExtension = "img"
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
                
                for i in 0..<backgroundDoc.pageCount {
                    guard let page = backgroundDoc.page(at: i) else { continue }
                    let pageRect = page.bounds(for: .mediaBox)
                    let image = page.thumbnail(of: pageRect.size, for: .mediaBox)
                    
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let data = bitmap.representation(using: format, properties: [:]) {
                        
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
    
    func exportToText() {
        guard let doc = document, let snapshot = doc.dataRepresentation() else {
            pushLog("Export failed: couldn't read current document state")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (currentURL?.deletingPathExtension().lastPathComponent ?? "Document") + ".txt"
        
        if panel.runModal() == .OK, let url = panel.url {
            isDocumentLoading = true
            loadingStatus = "Exporting text..."
            
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
                
                var fullText = ""
                for i in 0..<backgroundDoc.pageCount {
                    if let page = backgroundDoc.page(at: i), let text = page.string {
                        fullText += "--- Page \(i + 1) ---\n\n"
                        fullText += text
                        fullText += "\n\n"
                    }
                }
                
                try? fullText.write(to: url, atomically: true, encoding: .utf8)
                
                DispatchQueue.main.async {
                    self?.pushLog("Exported text to \(url.lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    func exportSelectedPages() {
        guard let doc = document else { return }
        let targets = selectedPageIDs.sorted()
        guard !targets.isEmpty else { return }

        let exportDocument = PDFDocument()
        for (offset, index) in targets.enumerated() {
            if let page = doc.page(at: index),
               let copy = page.copy() as? PDFPage {
                exportDocument.insert(copy, at: offset)
            }
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Selection.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            exportDocument.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            pushLog("Exported \(targets.count) page(s) to \(url.lastPathComponent)")
        }
    }

    func renameOutline(_ row: OutlineRow, title: String) {
        let sanitized = PDFStringNormalizer.normalize(title, context: "outline rename") ?? ""
        row.outline.label = sanitized
        refreshOutline()
        let loggedTitle = sanitized.isEmpty ? "Untitled" : sanitized
        pushLog("Renamed bookmark to \"\(loggedTitle)\"")
    }

    func deleteOutline(_ row: OutlineRow) {
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

        if let root = doc.outlineRoot {
            root.insertChild(outline, at: root.numberOfChildren)
        } else {
            let root = PDFOutline()
            let rootLabel = PDFStringNormalizer.normalizedNonEmpty(doc.documentURL?.lastPathComponent,
                                                                   context: "outline root title") ?? "Bookmarks"
            root.label = rootLabel
            root.insertChild(outline, at: 0)
            doc.outlineRoot = root
        }
        refreshOutline()
        pushLog("Added bookmark \"\(outline.label ?? "Untitled")\"")
    }

    func focus(annotation row: AnnotationRow) {
        guard let page = row.annotation.page else { return }
        let bounds = row.annotation.bounds
        let destination = PDFDestination(page: page,
                                         at: CGPoint(x: bounds.midX, y: bounds.midY))
        pdfView?.go(to: destination)
    }

    func delete(annotation row: AnnotationRow) {
        row.annotation.page?.removeAnnotation(row.annotation)
        refreshAnnotations()
        pushLog("Removed annotation")
    }

    func addFormField(kind: FormFieldKind, name: String, rect: CGRect) {
        guard let doc = document else { return }
        guard let page = pdfView?.currentPage ?? doc.page(at: 0) else { return }
        let requestedName = PDFStringNormalizer.normalize(name, context: "form field name") ?? ""
        let fieldName = requestedName.isEmpty ? kind.rawValue : requestedName
        let annotation: PDFAnnotation
        switch kind {
        case .text:
            annotation = PDFFormBuilder.makeTextField(name: fieldName, rect: rect)
            annotation.font = NSFont.systemFont(ofSize: 12)
            annotation.widgetStringValue = ""
            annotation.widgetDefaultStringValue = ""
        case .checkbox:
            annotation = PDFFormBuilder.makeCheckbox(name: fieldName, rect: rect)
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
        refreshAnnotations()
        pushLog("Added \(kind.rawValue)")
    }

    func applyWatermark(text: String,
                        fontSize: CGFloat,
                        color: NSColor,
                        opacity: CGFloat,
                        rotation: CGFloat,
                        position: WatermarkPosition,
                        margin: CGFloat) throws {
        guard let document else { throw PDFOpsError.missingDocument }
        PDFOps.applyWatermark(document: document,
                              text: text,
                              fontSize: fontSize,
                              color: color,
                              opacity: opacity,
                              rotation: rotation,
                              position: position,
                              margin: margin)
        refreshAnnotations()
        pushLog("Watermark applied")
    }

    func applyHeaderFooter(header: String,
                           footer: String,
                           margin: CGFloat,
                           fontSize: CGFloat) throws {
        guard let document else { throw PDFOpsError.missingDocument }
        PDFOps.applyHeaderFooter(document: document,
                                 header: header,
                                 footer: footer,
                                 margin: margin,
                                 fontSize: fontSize)
        refreshAnnotations()
        pushLog("Header/Footer applied")
    }

    func applyBatesNumbers(prefix: String,
                           start: Int,
                           digits: Int,
                           placement: BatesPlacement,
                           margin: CGFloat,
                           fontSize: CGFloat) throws {
        guard let document else { throw PDFOpsError.missingDocument }
        PDFOps.applyBatesNumbers(document: document,
                                 prefix: prefix,
                                 start: start,
                                 digits: digits,
                                 placement: placement,
                                 margin: margin,
                                 fontSize: fontSize)
        refreshAnnotations()
        pushLog("Bates numbers applied")
    }

    func crop(inset: CGFloat, target: CropTarget) throws {
        guard let document else { throw PDFOpsError.missingDocument }
        PDFOps.crop(document: document, inset: inset, target: target)
        refreshPages()
        pushLog("Cropped pages")
    }

    func optimize() throws -> Data {
        guard let document,
              let data = PDFOps.optimize(document: document) else {
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
                                              guard let self = self, self.currentURL == url else { return }
                                              self.updateValidationStatus(processed: processed, total: total)
                                          },
                                          completion: { [weak self] result in
                                              guard let self = self, self.currentURL == url else { return }
                                              self.validationMode = .idle
                                              self.isFullValidationRunning = false
                                              self.validationStatus = nil
                                              switch result {
                                              case .success(let sanitized):
                                                  self.pushLog("Validated \(sanitized.pageCount) pages")
                                              case .failure(let error):
                                                  if case PDFDocumentSanitizerError.cancelled = error { return }
                                                  self.pushLog("⚠️ \(error.localizedDescription)")
                                                  self.present(error)
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

        let targetSize = snapshotTargetSize
        let docURL = doc.documentURL
        let docData: Data?
        if !DocumentProfile.from(pageCount: doc.pageCount).isMassive {
            docData = doc.dataRepresentation()
        } else {
            // For very large documents, avoid serializing the entire file.
            docData = nil
        }

        // Build a scale bucket to improve cache hit rate.
        let mediaWidth = max(targetSize.width, 1)
        let bucket = Int(mediaWidth.rounded(.toNearestOrEven))

        let request = PDFRenderRequest(kind: .thumbnail,
                                       pageIndex: index,
                                       scaleBucket: bucket,
                                       size: targetSize)

        renderService.image(for: request,
                            documentURL: docURL,
                            documentData: docData,
                            priority: .high) { [weak self] image in
            guard let self else { return }
            self.inflightLock.lock()
            self.inflightThumbnails.remove(index)
            self.inflightLock.unlock()

            guard let image else { return }
            self.thumbnailCache.setObject(image, forKey: key)
            self.updateSnapshot(at: index, thumbnail: image)
        }
    }

    func prefetchThumbnails(around centerIndex: Int,
                            window: Int = 2,
                            farWindow: Int = 6) {
        guard let doc = document else { return }
        let sp = PerfLog.begin("StudioPrefetch")
        defer { PerfLog.end("StudioPrefetch", sp) }
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
        if !DocumentProfile.from(pageCount: doc.pageCount).isMassive {
            docData = doc.dataRepresentation()
        } else {
            docData = nil
        }

        // Near window (±window) with high priority.
        for offset in -window...window {
            let idx = centerIndex + offset
            guard let request = makeRequest(idx) else { continue }
            if thumbnailCache.object(forKey: NSNumber(value: idx)) != nil { continue }
            renderService.image(for: request,
                                documentURL: docURL,
                                documentData: docData,
                                priority: .veryHigh) { [weak self] image in
                guard let self, let image else { return }
                let key = NSNumber(value: idx)
                self.thumbnailCache.setObject(image, forKey: key)
                self.updateSnapshot(at: idx, thumbnail: image)
            }
        }

        // Far window (±farWindow) with lower priority.
        for offset in -(farWindow)...farWindow {
            if abs(offset) <= window { continue }
            let idx = centerIndex + offset
            guard let request = makeRequest(idx) else { continue }
            if thumbnailCache.object(forKey: NSNumber(value: idx)) != nil { continue }
            renderService.image(for: request,
                                documentURL: docURL,
                                documentData: docData,
                                priority: .low) { [weak self] image in
                guard let self, let image else { return }
                let key = NSNumber(value: idx)
                self.thumbnailCache.setObject(image, forKey: key)
                self.updateSnapshot(at: idx, thumbnail: image)
            }
        }
    }





    private func updateSnapshot(at index: Int, thumbnail: CGImage) {
        guard index >= 0 && index < pageSnapshots.count else { return }
        
        Task { [weak self] in
            guard let self else { return }
            await self.snapshotUpdateThrottle.run { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    guard index >= 0 && index < self.pageSnapshots.count else { return }
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
         completion: @escaping ([PageSnapshot], Bool) -> Void) {
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

        for index in 0..<pageCount {
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
           let cgDoc = CGPDFDocument(provider) {
            return cgDoc
        }
        if let data = document.dataRepresentation(),
           let provider = CGDataProvider(data: data as CFData) {
            return CGPDFDocument(provider)
        }
        return nil
    }

    private static func makeSnapshotsUsingPDFKit(document: PDFDocument, targetSize: CGSize) -> [PageSnapshot] {
        var items: [PageSnapshot] = []
        items.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
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
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
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
            CGPoint(x: rect.maxX - handleSize, y: rect.maxY - handleSize)
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
