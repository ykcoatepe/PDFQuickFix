import Foundation
import PDFKit
import AppKit
import CoreGraphics

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
final class StudioController: NSObject, ObservableObject, PDFViewDelegate {
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

        validationRunner.openDocument(at: url,
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
                                              self.finishOpen(document: doc, url: url)
                                          case .failure(let error):
                                              self.handleOpenError(error)
                                          }
                                      })
    }

    private func finishOpen(document newDocument: PDFDocument, url: URL) {
        let signpostID = PerfLog.begin("StudioOpen")
        defer { PerfLog.end("StudioOpen", signpostID) }
        
        document = newDocument
        currentURL = url
        isLargeDocument = newDocument.pageCount > largeDocumentPageThreshold
        resetThumbnailState()
        pdfView?.document = newDocument
        applyPDFViewConfiguration()
        refreshAll()
        pushLog("Opened \(url.lastPathComponent)")
        validationStatus = nil
        validationMode = .idle
        isFullValidationRunning = false

        let shouldSkipAutoValidation = DocumentValidationRunner.shouldSkipQuickValidation(
            estimatedPages: nil,
            resolvedPageCount: newDocument.pageCount
        )
        if !shouldSkipAutoValidation {
            scheduleValidation(for: url, pageLimit: 10, mode: .quick)
        }
    }

    private func handleOpenError(_ error: Error) {
        document = nil
        pdfView?.document = nil
        currentURL = nil
        isLargeDocument = false
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
        if doc.pageCount >= DocumentValidationRunner.massiveDocumentPageThreshold {
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
        if doc.pageCount >= DocumentValidationRunner.massiveDocumentPageThreshold {
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
        let isMassive = pages >= DocumentValidationRunner.massiveDocumentPageThreshold
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
        if doc.pageCount < DocumentValidationRunner.massiveDocumentPageThreshold {
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
        if doc.pageCount < DocumentValidationRunner.massiveDocumentPageThreshold {
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
