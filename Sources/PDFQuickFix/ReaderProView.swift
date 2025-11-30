import SwiftUI
@preconcurrency import PDFKit
import AppKit
import UniformTypeIdentifiers

// Controller coordinating PDF viewing, search, and page operations.
@MainActor
final class ReaderControllerPro: NSObject, ObservableObject, PDFActionable {
    @Published var document: PDFDocument?
    @Published var currentPageIndex: Int = 0
    @Published var zoomScale: CGFloat = 1.0
    @Published var searchQuery: String = ""
    @Published var searchMatches: [PDFSelection] = []
    @Published var currentMatchIndex: Int? = nil
    @Published var isSidebarVisible: Bool = true
    @Published var isRightPanelVisible: Bool = false
    @Published var isProcessing: Bool = false
    
    func toggleRightPanel() {
        isRightPanelVisible.toggle()
    }
    @Published var log: String = ""
    @Published var validationStatus: String?
    @Published var isFullValidationRunning: Bool = false
    @Published private(set) var currentURL: URL?
    @Published var isLoadingDocument: Bool = false
    @Published var loadingStatus: String?
    @Published var isLargeDocument: Bool = false
    @Published var isMassiveDocument: Bool = false
    @Published var isPartialLoad: Bool = false

    weak var pdfView: PDFView?

    private var findObserver: NSObjectProtocol?
    private let validationRunner = DocumentValidationRunner()
    private var searchDebounceWorkItem: DispatchWorkItem?
    private enum ValidationMode { case idle, quick, full }
    private var validationMode: ValidationMode = .idle
    private let largeDocumentPageThreshold = DocumentValidationRunner.largeDocumentPageThreshold

    deinit {
        if let observer = findObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        validationRunner.cancelAll()
    }

    func open(url: URL) {
        validationRunner.cancelValidation()
        validationRunner.cancelOpen()
        isLoadingDocument = true
        loadingStatus = "Opening \(url.lastPathComponent)…"
        let readerOpenSP = PerfLog.begin("ReaderOpen")
        #if DEBUG
        let openStart = Date()
        #endif


        let massiveThreshold = DocumentValidationRunner.massiveDocumentPageThreshold

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let rawDoc = PDFDocument(url: url) else {
                DispatchQueue.main.async {
                    self.isLoadingDocument = false
                    self.loadingStatus = nil
                    self.handleOpenError(PDFDocumentSanitizerError.unableToOpen(url))
                    PerfLog.end("ReaderOpen", readerOpenSP)
                }
                return
            }

            let pageCount = rawDoc.pageCount
            let isMassive = pageCount >= massiveThreshold

            if isMassive {
                DispatchQueue.main.async {
                    self.loadingStatus = nil
                    self.isLoadingDocument = false
                    self.finishOpen(document: rawDoc, url: url)
                    #if DEBUG
                    let duration = Date().timeIntervalSince(openStart)
                    PerfMetrics.shared.recordReaderOpen(duration: duration)
                    #endif
                    PerfLog.end("ReaderOpen", readerOpenSP)
                }
            } else {
                DispatchQueue.main.async {
                    self.validationRunner.openDocument(at: url,
                                                      quickValidationPageLimit: 0,
                                                      progress: { [weak self] processed, total in
                                                          guard let self = self else { return }
                                                          guard total > 0 else { return }
                                                          let clamped = min(processed, total)
                                                          self.loadingStatus = "Validating \(clamped)/\(total)"
                                                      },
                                                      completion: { [weak self] result in
                                                          guard let self = self else { return }
                                                          self.isLoadingDocument = false
                                                          self.loadingStatus = nil
                                                          switch result {
                                                          case .success(let doc):
                                                              self.finishOpen(document: doc, url: url)
                                                              #if DEBUG
                                                              let duration = Date().timeIntervalSince(openStart)
                                                              PerfMetrics.shared.recordReaderOpen(duration: duration)
                                                              #endif
                                                              PerfLog.end("ReaderOpen", readerOpenSP)
                                                          case .failure(let error):
                                                              self.handleOpenError(error)
                                                              PerfLog.end("ReaderOpen", readerOpenSP)
                                                          }
                                                      })
                }
            }
        }
    }

    private func finishOpen(document newDocument: PDFDocument, url: URL) {
        let sp = PerfLog.begin("ReaderApplyDocument")
        defer { PerfLog.end("ReaderApplyDocument", sp) }
        currentURL = url
        document = newDocument
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let profile = DocumentProfile.from(pageCount: newDocument.pageCount, fileSizeBytes: fileSize)
        isLargeDocument = profile.isLarge
        isMassiveDocument = profile.isMassive

        if !isMassiveDocument {
            pdfView?.document = newDocument
            configurePDFView()
        } else {
            // Massive docs: avoid attaching to PDFView to prevent UI lockups.
            pdfView?.document = nil
        }
        currentPageIndex = 0
        searchMatches.removeAll()
        validationStatus = nil
        validationMode = .idle
        validationStatus = nil
        validationMode = .idle
        isFullValidationRunning = false
        isPartialLoad = false

        let shouldSkipAutoValidation = DocumentValidationRunner.shouldSkipQuickValidation(
            estimatedPages: nil,
            resolvedPageCount: newDocument.pageCount
        )
        let isMassive = profile.isMassive
        if !isMassive && !shouldSkipAutoValidation {
            scheduleValidation(for: url, pageLimit: 10, mode: .quick)
        }
        
        // Add to Recent Files
        DispatchQueue.main.async {
            RecentFilesManager.shared.add(url: url, pageCount: newDocument.pageCount)
            NotificationCenter.default.post(name: .readerDidOpenDocument, object: url)
        }
    }

    private func handleOpenError(_ error: Error) {
        document = nil
        pdfView?.document = nil
        currentURL = nil
        isLargeDocument = false
        validationStatus = nil
        isFullValidationRunning = false
        validationMode = .idle
        log = "❌ \(error.localizedDescription)"
        present(error)
    }

    func validateFully() {
        guard let url = currentURL, !isFullValidationRunning else { return }
        scheduleValidation(for: url, pageLimit: nil, mode: .full)
    }
    
    func saveAs() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-copy.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            doc.write(to: url)
        }
    }
    
    func exportToImages(format: NSBitmapImageRep.FileType) {
        guard let doc = document, let snapshot = doc.dataRepresentation() else {
            log = "Export failed: couldn't read current document state"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a folder to save images"
        panel.directoryURL = doc.documentURL?.deletingLastPathComponent()
        
        if panel.runModal() == .OK, let outputDir = panel.url {
            let fileExtension: String
            switch format {
            case .jpeg: fileExtension = "jpg"
            case .png: fileExtension = "png"
            case .tiff: fileExtension = "tiff"
            default: fileExtension = "img"
            }
            
            isProcessing = true

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Create a new PDFDocument instance for background processing
                guard let backgroundDoc = PDFDocument(data: snapshot) else {
                    Task { @MainActor [weak self] in
                        self?.isProcessing = false
                        self?.log = "Export failed: couldn't read current document state"
                    }
                    return
                }
                
                for i in 0..<backgroundDoc.pageCount {
                    guard let page = backgroundDoc.page(at: i) else { continue }
                    let pageRect = page.bounds(for: .mediaBox)
                    // Use PDFPage.thumbnail to generate image

                    
                    let image = page.thumbnail(of: pageRect.size, for: .mediaBox)
                    if let tiffData = image.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let data = bitmap.representation(using: format, properties: [:]) {
                        
                        let filename = "Page_\(i + 1).\(fileExtension)"
                        let fileURL = outputDir.appendingPathComponent(filename)
                        try? data.write(to: fileURL)
                    }
                }
                
                Task { @MainActor [weak self] in
                    self?.isProcessing = false
                    NSWorkspace.shared.activateFileViewerSelecting([outputDir])
                }
            }
        }
    }
    
    func exportToText() {
        guard let doc = document, let snapshot = doc.dataRepresentation() else {
            log = "Export failed: couldn't read current document state"
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Document") + ".txt"
        
        if panel.runModal() == .OK, let url = panel.url {
            isProcessing = true

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Create a new PDFDocument instance for background processing
                guard let backgroundDoc = PDFDocument(data: snapshot) else {
                    Task { @MainActor [weak self] in
                        self?.isProcessing = false
                        self?.log = "Export failed: couldn't read current document state"
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
                
                Task { @MainActor [weak self] in
                    self?.isProcessing = false
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
    
    func printDoc() {
        guard let view = pdfView else { return }
        let operation = NSPrintOperation(view: view)
        operation.jobTitle = document?.documentURL?.lastPathComponent ?? "PDFQuickFix"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
    
    // MARK: - Search
    
    func find(_ text: String) {
        searchMatches.removeAll()
        currentMatchIndex = nil
        guard let doc = document, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if DocumentProfile.from(pageCount: doc.pageCount).isMassive {
            log = "Search disabled for massive documents (too many pages)."
            return
        }
        
        findObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        findObserver = NotificationCenter.default.addObserver(
            forName: .PDFDocumentDidFindMatch,
            object: doc,
            queue: .main
        ) { [weak self] note in
            guard let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.searchMatches.append(selection)
                if let idx = self.searchMatches.indices.last, self.currentMatchIndex == nil {
                    self.focusSelection(selection, at: idx)
                }
            }
        }
        
        doc.cancelFindString()
        doc.beginFindString(text, withOptions: [.caseInsensitive])
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
        let nextIndex: Int
        if let current = currentMatchIndex {
            nextIndex = (current + 1) % searchMatches.count
        } else {
            nextIndex = 0
        }
        focusSelection(searchMatches[nextIndex], at: nextIndex)
    }

    func findPrev() {
        guard !searchMatches.isEmpty else { return }
        let prevIndex: Int
        if let current = currentMatchIndex {
            prevIndex = (current - 1 + searchMatches.count) % searchMatches.count
        } else {
            prevIndex = max(searchMatches.count - 1, 0)
        }
        focusSelection(searchMatches[prevIndex], at: prevIndex)
    }
    
    // MARK: - Annotations
    
    func applyMark(_ subtype: PDFAnnotationSubtype, color: NSColor) {
        guard let view = pdfView, let selection = view.currentSelection else { return }
        for page in selection.pages {
            let rects = annotationRects(for: selection, on: page)
            for rect in rects {
                let annotation = PDFAnnotation(bounds: rect, forType: subtype, withProperties: nil)
                annotation.color = color
                page.addAnnotation(annotation)
            }
        }
    }
    
    func addStickyNote() {
        guard let page = pdfView?.currentPage else { return }
        let bounds = page.bounds(for: .mediaBox)
        let noteBounds = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        let note = PDFAnnotation(bounds: noteBounds, forType: .text, withProperties: nil)
        note.iconType = .note
        note.contents = "Note"
        page.addAnnotation(note)
    }
    
    func loadPartialDocument(pageLimit: Int = 50) {
        guard let originalDoc = document else { return }
        let partialDoc = PDFDocument()
        let count = min(originalDoc.pageCount, pageLimit)
        
        for i in 0..<count {
            guard let page = originalDoc.page(at: i),
                  let copy = page.copy() as? PDFPage else { continue }
            partialDoc.insert(copy, at: i)
        }
        
        self.pdfView?.document = partialDoc
        self.configurePDFView()
        self.isMassiveDocument = false // Temporarily treat as normal for viewing
        self.isPartialLoad = true
        
        // Notify user
        log = "Loaded first \(count) pages for preview."
    }
    
    func loadFullDocument() {
        guard let originalDoc = document else { return }
        
        // Re-evaluate profile to restore massive state if needed
        let profile = DocumentProfile.from(pageCount: originalDoc.pageCount)
        self.isMassiveDocument = profile.isMassive
        self.isPartialLoad = false
        
        // If it was massive, we are now "forcing" it to load fully?
        // Or should we just return to the massive placeholder?
        // The user clicked "Load All", so we should try to load it into the view.
        // We will set isMassiveDocument = false to allow the view to render it,
        // but we might want to warn or keep some flags.
        // For now, let's allow it but maybe keep isLargeDocument = true for tuning.
        
        // Actually, if we set isMassiveDocument = false, the view will try to render.
        // Let's do that, assuming the user knows what they are doing.
        self.isMassiveDocument = false
        
        self.pdfView?.document = originalDoc
        self.configurePDFView()
        
        log = "Loaded full document (\(originalDoc.pageCount) pages)."
    }
    
    // MARK: - Page operations
    
    func rotateLeft() {
        rotateCurrentPageLeft()
    }
    
    func rotateRight() {
        rotateCurrentPageRight()
    }
    
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
        // PDFKit repaints automatically, but we can force a layout update if needed.
        // For now, this is a placeholder for any side effects.
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
    
    func deleteCurrentPage() {
        guard let doc = document, let page = pdfView?.currentPage else { return }
        let index = doc.index(for: page)
        doc.removePage(at: index)
    }

    func setZoom(percent: Double) {
        guard let view = pdfView, percent > 1 else { return }
        let clamped = min(max(percent, 10), 800) // 10%–800%
        let scale = CGFloat(clamped) / 100.0
        view.autoScales = false
        view.minScaleFactor = max(view.minScaleFactor, scale / 4)
        view.maxScaleFactor = max(view.maxScaleFactor, scale * 4)
        view.scaleFactor = scale
        zoomScale = view.scaleFactor
    }

    func zoomIn() {
        guard let view = pdfView else { return }
        view.zoomIn(nil)
        zoomScale = view.scaleFactor
    }

    func zoomOut() {
        guard let view = pdfView else { return }
        view.zoomOut(nil)
        zoomScale = view.scaleFactor
    }
    
    // MARK: - Helpers
    
    private func configurePDFView() {
        guard let view = pdfView else { return }
        view.applyPerformanceTuning(isLargeDocument: isLargeDocument,
                                    desiredDisplayMode: .singlePageContinuous,
                                    resetScale: true)
        view.delegate = self
        zoomScale = view.scaleFactor
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
                                              case .success:
                                                  self.currentPageIndex = self.currentDisplayedPageIndex() ?? self.currentPageIndex
                                                  self.searchMatches.removeAll()
                                              case .failure(let error):
                                                  if case PDFDocumentSanitizerError.cancelled = error { return }
                                                  self.log = "❌ \(error.localizedDescription)"
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

    private func currentDisplayedPageIndex() -> Int? {
        guard let view = pdfView, let doc = document, let current = view.currentPage else { return nil }
        let index = doc.index(for: current)
        return index >= 0 ? index : nil
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
extension ReaderControllerPro: FileExportable {}

// PDFViewDelegate conformance kept nonisolated to satisfy protocol requirements
// while updating state on the main actor explicitly.
extension ReaderControllerPro: PDFViewDelegate {
    nonisolated func pdfViewWillChangeScaleFactor(_ sender: PDFView, toScale scale: CGFloat) -> CGFloat {
        Task { @MainActor [weak self] in
            self?.zoomScale = scale
        }
        return scale
    }
}

struct ReaderProView: View {
    @ObservedObject var controller: ReaderControllerPro
    @Binding var selectedTab: AppMode
    @EnvironmentObject private var documentHub: SharedDocumentHub
    @State private var quickFixPresented = false
    @State private var standaloneQuickFixPresented = false
    @State private var lastOpenedURL: URL?
    @State private var droppedURL: URL?

    @State private var showEncrypt = false
    @State private var userPassword = ""
    @State private var ownerPassword = ""
    
    // Computed profile based on current document
    private var profile: DocumentProfile {
        if let doc = controller.document {
            return DocumentProfile.from(pageCount: doc.pageCount)
        }
        return .empty
    }
    
    var body: some View {
            ReaderShellView(controller: controller,
                            quickFixPresented: $quickFixPresented,
                            standaloneQuickFixPresented: $standaloneQuickFixPresented,
                            showEncrypt: $showEncrypt,
                            profile: profile,
                            selectedTab: $selectedTab,
                            syncEnabled: $documentHub.syncEnabled)
            .focusedSceneValue(\.fileExportable, controller)
        .focusedSceneValue(\.pdfActionable, controller)
        .onDrop(of: [.fileURL, .url, .pdf], delegate: PDFURLDropDelegate { url in
            droppedURL = url
        })
            .onChange(of: droppedURL) { newValue in
                guard let url = newValue else { return }
                droppedURL = nil
                lastOpenedURL = url
                controller.open(url: url)
            }
            .sheet(isPresented: $quickFixPresented) {
                QuickFixSheet(inputURL: $lastOpenedURL) { output in
                    if let output {
                        lastOpenedURL = output
                        controller.open(url: output)
                    }
                }
                .frame(minWidth: 720, minHeight: 520)
            }
            .sheet(isPresented: $standaloneQuickFixPresented) {
                QuickFixTab()
                    .frame(minWidth: 900, minHeight: 620)
            }
            .sheet(isPresented: $showEncrypt) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Encrypt PDF").font(.title3).bold()
                    SecureField("User password", text: $userPassword)
                    SecureField("Owner password (optional)", text: $ownerPassword)
                    HStack {
                        Spacer()
                        Button("Cancel") { showEncrypt = false }
                        Button("Encrypt") {
                            encryptCurrent()
                            showEncrypt = false
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(controller.document == nil || userPassword.isEmpty)
                    }
                }
                .padding(16)
                .frame(minWidth: 420)
            }
            .onAppear {
                syncFromHub()
                if documentHub.syncEnabled, documentHub.currentURL == nil {
                    documentHub.update(url: controller.currentURL, from: .reader)
                }
            }
            .onChange(of: controller.currentURL) { url in
                if documentHub.syncEnabled {
                    documentHub.update(url: url, from: .reader)
                }
            }
            .onChange(of: documentHub.currentURL) { _ in
                syncFromHub()
            }
    }
    
    private func encryptCurrent() {
        guard let doc = controller.document else { return }
        guard let data = PDFSecurity.encrypt(
            document: doc,
            userPassword: userPassword,
            ownerPassword: ownerPassword.isEmpty ? nil : ownerPassword,
            keyLength: 256
        ) else { return }
        
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Encrypted") + "-encrypted.pdf"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try data.write(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                print("Encrypt write error: \(error)")
            }
        }
        userPassword = ""
        ownerPassword = ""
    }

    private func syncFromHub() {
        guard documentHub.syncEnabled,
              documentHub.lastSource == .studio,
              let target = documentHub.currentURL,
              controller.currentURL != target else { return }
        controller.open(url: target)
    }
}

struct ReaderHomeView: View {
    @ObservedObject var controller: ReaderControllerPro
    @StateObject private var recentFiles = RecentFilesManager.shared
    @State private var isDragging = false
    
    // Grid layout for recent files (2 columns)
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 40) {
                Spacer()
                    .frame(height: 60)
                
                // Drop Zone
                Button(action: {
                    chooseFile()
                }) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppTheme.Metrics.dropZoneCornerRadius, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: AppTheme.Metrics.dropZoneBorderWidth, dash: [8]))
                            .foregroundColor(isDragging ? Color.accentColor : AppTheme.Colors.dropZoneStroke)
                            .background(
                                RoundedRectangle(cornerRadius: AppTheme.Metrics.dropZoneCornerRadius, style: .continuous)
                                    .fill(isDragging ? AppTheme.Colors.dropZoneFillHighlighted : AppTheme.Colors.dropZoneFill)
                            )
                        
                        VStack(spacing: 20) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 64))
                                .foregroundColor(AppTheme.Colors.secondaryText)
                            
                            VStack(spacing: 8) {
                                Text("Drop PDF here")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(AppTheme.Colors.primaryText)
                                Text("or click to browse files")
                                    .font(.body)
                                    .foregroundColor(AppTheme.Colors.secondaryText)
                            }
                        }
                    }
                    .frame(height: 320)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onDrop(of: [.fileURL, .url, .pdf], isTargeted: $isDragging) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url {
                            DispatchQueue.main.async {
                                controller.open(url: url)
                            }
                        }
                    }
                    return true
                }
                
                // Recent Files
                if !recentFiles.recentFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Recent Files")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(AppTheme.Colors.primaryText)
                            Spacer()
                            Button("Show All") {
                                // Action for showing all files
                            }
                            .buttonStyle(.link)
                            .foregroundColor(AppTheme.Colors.secondaryText)
                        }
                        
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(recentFiles.recentFiles.prefix(6)) { file in
                                Button(action: {
                                    controller.open(url: file.url)
                                }) {
                                    HStack(spacing: 16) {
                                        // Thumbnail / Icon
                                        ZStack {
                                            RoundedRectangle(cornerRadius: AppTheme.Metrics.thumbnailCornerRadius, style: .continuous)
                                                .fill(AppTheme.Colors.thumbnailBackground)
                                                .frame(width: 48, height: 64)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: AppTheme.Metrics.thumbnailCornerRadius, style: .continuous)
                                                        .stroke(AppTheme.Colors.thumbnailBorder, lineWidth: 0.5)
                                                )
                                                .shadow(color: AppTheme.Shadows.card.opacity(0.57), radius: 2, x: 0, y: 1)
                                            
                                            // Simplified content lines
                                            VStack(alignment: .leading, spacing: 4) {
                                                RoundedRectangle(cornerRadius: 1)
                                                    .fill(Color.gray.opacity(0.3))
                                                    .frame(width: 32, height: 3)
                                                
                                                RoundedRectangle(cornerRadius: 1)
                                                    .fill(Color.gray.opacity(0.3))
                                                    .frame(width: 24, height: 3)
                                                
                                                Spacer()
                                            }
                                            .padding(8)
                                        }
                                        
                                        // Info
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(file.name)
                                                .font(.headline)
                                                .fontWeight(.medium)
                                                .foregroundColor(AppTheme.Colors.primaryText)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            
                                            Text("Last opened: \(file.date.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption)
                                                .foregroundColor(AppTheme.Colors.secondaryText)
                                        }
                                        Spacer()
                                    }
                                    .padding(16)
                                    .background(
                                        RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                                            .fill(AppTheme.Colors.cardBackground)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                                            .stroke(AppTheme.Colors.cardBorder, lineWidth: AppTheme.Metrics.cardBorderWidth)
                                    )
                                    .shadow(color: AppTheme.Shadows.card, radius: 6, x: 0, y: 3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .background(AppTheme.Colors.background)
    }
    
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.open(url: url)
        }
    }
}

// MARK: - Reader Shell View
struct ReaderShellView: View {
    @ObservedObject var controller: ReaderControllerPro
    @Binding var quickFixPresented: Bool
    @Binding var standaloneQuickFixPresented: Bool
    @Binding var showEncrypt: Bool
    let profile: DocumentProfile
    @Binding var selectedTab: AppMode
    @StateObject private var recentFilesManager = RecentFilesManager.shared
    @Binding var syncEnabled: Bool
    @State private var sidebarWidth: CGFloat = 260
    @State private var sidebarDragStart: CGFloat = 260
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Unified Toolbar
            
            // 2. Main Content Area
            HStack(spacing: 0) {
                // Left Sidebar (Thumbnails / Outline)
                if controller.isSidebarVisible {
                    HStack(spacing: 0) {
                        ReaderSidebarLeft(controller: controller, profile: profile)
                            .frame(width: sidebarWidth)
                            .transition(.move(edge: .leading))

                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 6)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        sidebarWidth = clampSidebarWidth(sidebarDragStart + value.translation.width)
                                    }
                                    .onEnded { value in
                                        sidebarWidth = clampSidebarWidth(sidebarDragStart + value.translation.width)
                                        sidebarDragStart = sidebarWidth
                                    }
                            )
                            .onHover { hovering in
                                if hovering {
                                    NSCursor.resizeLeftRight.set()
                                } else {
                                    NSCursor.arrow.set()
                                }
                            }
                    }

                    Divider()
                }
                
                // Center Canvas
                // Center Canvas or Home View
                if controller.document != nil {
                    ReaderCanvas(controller: controller, profile: profile)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppTheme.Colors.background)
                        .contextMenu {
                            if controller.document != nil {
                                Button {
                                    controller.rotateCurrentPageLeft()
                                } label: {
                                    Label("Rotate Left", systemImage: "rotate.left")
                                }
                                
                                Button {
                                    controller.rotateCurrentPageRight()
                                } label: {
                                    Label("Rotate Right", systemImage: "rotate.right")
                                }
                            }
                        }
                } else {
                    ReaderHomeView(
                        controller: controller
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                // Right Sidebar (Slide-in)
                if controller.isRightPanelVisible {
                    Divider()
                    ReaderSidebarRight(controller: controller, profile: profile)
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
            }
            
            ReaderStatusBar(controller: controller)
        }
        .background(AppTheme.Colors.background.ignoresSafeArea())
    }

    private func browseForDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.open(url: url)
        }
    }

    private func clampSidebarWidth(_ value: CGFloat) -> CGFloat {
        let minWidth: CGFloat = 180
        let maxWidth: CGFloat = 420
        return min(max(value, minWidth), maxWidth)
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

// Extension to support right panel toggle in controller
extension ReaderControllerPro {
    // Add this property to your controller if not present, or use a @Published in the view
    // For now, assuming we add it to the controller or manage it in the view.
    // Since ReaderControllerPro is a class, we can't easily add @Published via extension.
    // Let's assume we modify ReaderControllerPro to include isRightPanelVisible.
    // For this refactor, I will add a computed property wrapper or assume it exists.
    // Actually, let's add it to the controller class in the file.
    // But the toolbar needs to toggle it.
    // Let's add it to the controller class in the file.
}






// MARK: - Reader Sidebar Left (Pages / Outline)
struct ReaderSidebarLeft: View {
    @ObservedObject var controller: ReaderControllerPro
    let profile: DocumentProfile
    @State private var selection: Int = 0
    @State private var hoveredIndex: Int? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Segmented Control
            Picker("", selection: $selection) {
                Text("Pages").tag(0)
                Text("Outline").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(10)
            
            Divider()
            
            if controller.document == nil {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 24))
                        .foregroundColor(AppTheme.Colors.secondaryText)
                    Text("No pages yet")
                        .font(.caption)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if selection == 0 {
                    // Thumbnails
                    PDFThumbnailViewRepresentable(pdfView: controller.pdfView ?? PDFView())
                        .background(AppTheme.Colors.sidebarBackground)
                } else {
                    // Outline
                    if let root = controller.document?.outlineRoot {
                        List {
                            ReaderOutlineNode(node: root, controller: controller)
                        }
                        .listStyle(.sidebar)
                    } else {
                        VStack {
                            Spacer()
                            Text("No Outline Available")
                                .foregroundColor(AppTheme.Colors.secondaryText)
                            Spacer()
                        }
                    }
                }
            }
        }
        .background(
            ZStack {
                AppTheme.Colors.sidebarBackground
                VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
                    .ignoresSafeArea()
            }
        )
    }
}



// MARK: - Reader Sidebar Right (Comments / Info)
struct ReaderSidebarRight: View {
    @ObservedObject var controller: ReaderControllerPro
    let profile: DocumentProfile
    @State private var selectedTab: RightTab = .info
    
    enum RightTab { case info, comments }
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Image(systemName: "info.circle").tag(RightTab.info)
                Image(systemName: "text.bubble").tag(RightTab.comments)
            }
            .pickerStyle(.segmented)
            .padding(8)
            
            Divider()
            
            if selectedTab == .info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(label: "File", value: controller.currentURL?.lastPathComponent ?? "-")
                        InfoRow(label: "Pages", value: "\(controller.document?.pageCount ?? 0)")
                        InfoRow(label: "PDF Version", value: "\(controller.document?.majorVersion ?? 1).\(controller.document?.minorVersion ?? 0)")
                        if let attrs = controller.document?.documentAttributes {
                            InfoRow(label: "Author", value: attrs["Author"] as? String ?? "-")
                            InfoRow(label: "Creator", value: attrs["Creator"] as? String ?? "-")
                        }
                    }
                    .padding()
                }
            } else {
                Text("No Comments")
                    .foregroundColor(AppTheme.Colors.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.Colors.sidebarBackground)
    }
}


struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label).foregroundColor(AppTheme.Colors.secondaryText)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundColor(AppTheme.Colors.primaryText)
        }
        .font(.caption)
    }
}

// MARK: - Reader Status Bar
struct ReaderStatusBar: View {
    @ObservedObject var controller: ReaderControllerPro
    
    var body: some View {
        HStack(spacing: 12) {
            if let status = controller.validationStatus {
                Image(systemName: "checkmark.shield")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.primaryText)
                Text(status)
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.primaryText)
            } else {
                Text("Ready")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
            
            Spacer()
            
            if let selection = controller.pdfView?.currentSelection {
                Text("\(selection.pages.count) pages selected")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(AppTheme.Colors.cardBackground)
        .overlay(Divider(), alignment: .top)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let readerDidOpenDocument = Notification.Name("ReaderDidOpenDocument")
}

// MARK: - Reader Canvas
struct ReaderCanvas: View {
    @ObservedObject var controller: ReaderControllerPro
    let profile: DocumentProfile
    
    var body: some View {
        ZStack {
            if controller.document != nil && !controller.isMassiveDocument {
                ZStack(alignment: .top) {
                    PDFViewProRepresented(document: controller.document, controller: controller) { view in
                        controller.pdfView = view
                    }
                    .background(Color(NSColor.textBackgroundColor))
                    
                    if controller.isPartialLoad {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                            Text("Partial Load: First 50 pages")
                                .font(.caption)
                                .fontWeight(.medium)
                            
                            Spacer()
                            
                            Button("Load All") {
                                controller.loadFullDocument()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Material.regular)
                        .cornerRadius(8)
                        .shadow(radius: 2)
                        .padding(.top, 8)
                        .frame(maxWidth: 400)
                    }
                }
            } else if controller.isMassiveDocument, let url = controller.currentURL {
                VStack(spacing: 12) {
                    Text("Performance Mode Active")
                        .font(.headline)
                        .foregroundColor(AppTheme.Colors.primaryText)
                    Text("This document is too large for the full editor.")
                        .foregroundColor(AppTheme.Colors.secondaryText)
                    Button("Open in Preview") {
                        NSWorkspace.shared.open(url)
                    }
                    
                    Button("Load First 50 Pages") {
                        controller.loadPartialDocument()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("Open a PDF")
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
            
            if controller.isLoadingDocument {
                LoadingOverlayView(status: controller.loadingStatus ?? "Loading...")
            }
        }
    }
}

// MARK: - PDFView bridge

struct PDFViewProRepresented: NSViewRepresentable {
    var document: PDFDocument?
    var controller: ReaderControllerPro
    var didCreate: (PDFView) -> Void
    
    func makeNSView(context: Context) -> PDFView {
        let view = ReaderPDFView()
        view.controller = controller
        view.backgroundColor = .textBackgroundColor
        view.document = document
        view.applyPerformanceTuning(isLargeDocument: false,
                                    desiredDisplayMode: .singlePageContinuous,
                                    resetScale: true)
        didCreate(view)
        return view
    }
    
    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }
        if let readerView = nsView as? ReaderPDFView {
            readerView.controller = controller
        }
    }
}

class ReaderPDFView: PDFView {
    weak var controller: ReaderControllerPro?
    
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(NSMenuItem.separator())
        
        let rotateLeft = NSMenuItem(title: "Rotate Left 90°", action: #selector(rotateLeft(_:)), keyEquivalent: "")
        rotateLeft.target = self
        menu.addItem(rotateLeft)
        
        let rotateRight = NSMenuItem(title: "Rotate Right 90°", action: #selector(rotateRight(_:)), keyEquivalent: "")
        rotateRight.target = self
        menu.addItem(rotateRight)
        
        return menu
    }
    
    @objc private func rotateLeft(_ sender: Any?) {
        controller?.rotateCurrentPageLeft()
    }
    
    @objc private func rotateRight(_ sender: Any?) {
        controller?.rotateCurrentPageRight()
    }
}

// MARK: - Thumbnails bridge

struct ThumbnailProRepresentedView: NSViewRepresentable {
    var pdfViewGetter: () -> PDFView?
    
    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnails = PDFThumbnailView()
        thumbnails.backgroundColor = .clear
        thumbnails.thumbnailSize = NSSize(width: 120, height: 160)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.pdfView = pdfViewGetter()
        return thumbnails
    }
    
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        nsView.pdfView = pdfViewGetter()
    }
}

// MARK: - Extensions

extension PDFOutline {
    var level: Int {
        var lvl = 0
        var p = parent
        while p != nil {
            lvl += 1
            p = p?.parent
        }
        return lvl
    }
}
