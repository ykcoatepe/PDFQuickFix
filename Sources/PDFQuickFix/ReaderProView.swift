import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// Controller coordinating PDF viewing, search, and page operations.
final class ReaderControllerPro: NSObject, ObservableObject, PDFViewDelegate {
    @Published var document: PDFDocument?
    @Published var currentPageIndex: Int = 0
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
        isLargeDocument = newDocument.pageCount > largeDocumentPageThreshold
        isMassiveDocument = newDocument.pageCount >= DocumentValidationRunner.massiveDocumentPageThreshold

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
        isFullValidationRunning = false

        let shouldSkipAutoValidation = DocumentValidationRunner.shouldSkipQuickValidation(
            estimatedPages: nil,
            resolvedPageCount: newDocument.pageCount
        )
        let isMassive = newDocument.pageCount >= DocumentValidationRunner.massiveDocumentPageThreshold
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
    
    func saveCopy() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-copy.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            doc.write(to: url)
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
        if doc.pageCount >= DocumentValidationRunner.massiveDocumentPageThreshold {
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
            self?.searchMatches.append(selection)
            if let idx = self?.searchMatches.indices.last, self?.currentMatchIndex == nil {
                self?.focusSelection(selection, at: idx)
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
    
    // MARK: - Page operations
    
    func rotateCurrentPage(left: Bool) {
        guard let page = pdfView?.currentPage else { return }
        var rotation = page.rotation
        rotation += left ? -90 : 90
        if rotation < 0 { rotation += 360 }
        page.rotation = rotation % 360
    }
    
    func deleteCurrentPage() {
        guard let doc = document, let page = pdfView?.currentPage else { return }
        let index = doc.index(for: page)
        doc.removePage(at: index)
    }
    
    // MARK: - Helpers
    
    private func configurePDFView() {
        guard let view = pdfView else { return }
        view.applyPerformanceTuning(isLargeDocument: isLargeDocument,
                                    desiredDisplayMode: .singlePageContinuous,
                                    resetScale: true)
        view.delegate = self
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
                if documentHub.syncEnabled {
                    documentHub.update(url: controller.currentURL, from: .reader)
                }
            }
            .onChange(of: controller.currentURL) { url in
                if documentHub.syncEnabled {
                    documentHub.update(url: url, from: .reader)
                }
            }
            .onChange(of: documentHub.currentURL) { url in
                guard documentHub.syncEnabled,
                      documentHub.lastSource == .studio,
                      let url,
                      controller.currentURL != url else { return }
                controller.open(url: url)
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
}

struct ReaderHomeView: View {
    @ObservedObject var controller: ReaderControllerPro
    @StateObject private var recentFiles = RecentFilesManager.shared
    @State private var isDragging = false
    
    // Custom Colors - Zinc Palette
    private let bgDark = Color(red: 0.09, green: 0.09, blue: 0.11) // Zinc 950 (#18181B)
    private let cardBg = Color(red: 0.15, green: 0.15, blue: 0.17) // Zinc 900 (#27272A)
    private let dropZoneStroke = Color(white: 0.3)
    
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
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [8]))
                            .foregroundStyle(isDragging ? Color.accentColor : dropZoneStroke.opacity(0.5))
                            .background(isDragging ? Color.accentColor.opacity(0.1) : Color.clear)
                        
                        VStack(spacing: 20) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 64))
                                .foregroundStyle(.secondary)
                            
                            VStack(spacing: 8) {
                                Text("Drop PDF here")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("or click to browse files")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
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
                                .foregroundStyle(.white)
                            Spacer()
                            Button("Show All") {
                                // Action for showing all files
                            }
                            .buttonStyle(.link)
                            .foregroundStyle(.secondary)
                        }
                        
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(recentFiles.recentFiles.prefix(6)) { file in
                                Button(action: {
                                    controller.open(url: file.url)
                                }) {
                                    HStack(spacing: 16) {
                                        // Thumbnail / Icon
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color(white: 0.95))
                                                .frame(width: 48, height: 64)
                                                .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                                            
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
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            
                                            Text("Last opened: \(file.date.formatted(date: .abbreviated, time: .shortened))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(16)
                                    .background(cardBg)
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                                    .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
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
        .background(bgDark)
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
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. Unified Toolbar
            ReaderToolbar(controller: controller,
                          profile: profile,
                          selectedTab: $selectedTab,
                          quickFixPresented: $quickFixPresented,
                          showEncrypt: $showEncrypt,
                          browseForDocument: browseForDocument,
                          presentStandaloneQuickFix: {
                              standaloneQuickFixPresented = true
                          },
                          syncEnabled: $syncEnabled)
                .frame(height: 44)
                .zIndex(1)
            
            // 2. Main Content Area
            HStack(spacing: 0) {
                // Left Sidebar (Thumbnails / Outline)
                if controller.isSidebarVisible {
                    ReaderSidebarLeft(controller: controller, profile: profile)
                        .frame(width: 260)
                        .transition(.move(edge: .leading))
                    
                    Divider()
                }
                
                // Center Canvas
                // Center Canvas or Home View
                if controller.document != nil {
                    ReaderCanvas(controller: controller, profile: profile)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(NSColor.windowBackgroundColor))
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


// MARK: - Reader Toolbar
struct ReaderToolbar: View {
    @ObservedObject var controller: ReaderControllerPro
    let profile: DocumentProfile
    @Binding var selectedTab: AppMode
    @Binding var quickFixPresented: Bool
    @Binding var showEncrypt: Bool
    let browseForDocument: () -> Void
    let presentStandaloneQuickFix: () -> Void
    @Binding var syncEnabled: Bool
    
    var body: some View {
        ZStack {
            // Layer 1: Left and Right Controls
            HStack(alignment: .center, spacing: 12) {
            // Left Controls Group
            HStack(spacing: 16) {
                Button {
                    browseForDocument()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Open a PDF")

                HStack(spacing: 0) {
                    Button(action: { controller.pdfView?.goToPreviousPage(nil) }) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                        .disabled(controller.document == nil)

                        Button(action: { controller.pdfView?.goToNextPage(nil) }) {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.document == nil)
                    }

                    Text(zoomPercentage)
                        .font(.subheadline)
                        .monospacedDigit()
                        .frame(width: 45)

                    HStack(spacing: 4) {
                        Text("Page")
                        TextField("", value: pageBinding, formatter: NumberFormatter())
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.center)
                            .onSubmit {
                                let target = max(pageBinding.wrappedValue - 1, 0)
                                if let page = controller.document?.page(at: target) {
                                    controller.pdfView?.go(to: page)
                                }
                            }
                            .disabled(controller.document == nil)
                        Text("/ \(controller.document?.pageCount ?? 0)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }

                Spacer()

                // Right Controls Group
                HStack(spacing: 12) {
                    Toggle(isOn: $syncEnabled) {
                        Image(systemName: syncEnabled ? "link" : "link.slash")
                    }
                    .toggleStyle(.button)
                    .help(syncEnabled ? "Turn off Reader↔Studio sync" : "Turn on Reader↔Studio sync")

                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search in document", text: $controller.searchQuery)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                controller.find(controller.searchQuery)
                            }
                            .onChange(of: controller.searchQuery) { query in
                                controller.updateSearchQueryDebounced(query)
                            }
                            .disabled(controller.document == nil)
                        if !controller.searchMatches.isEmpty {
                            Text("\(controller.searchMatches.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                    .frame(width: 200)

                    HStack(spacing: 8) {
                        Button(action: { controller.findPrev() }) {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.searchMatches.isEmpty)

                        Button(action: { controller.findNext() }) {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                        .disabled(controller.searchMatches.isEmpty)

                        if !controller.searchMatches.isEmpty {
                            Menu {
                                ForEach(Array(controller.searchMatches.enumerated()), id: \.offset) { idx, match in
                                    Button {
                                        controller.focusSelection(match)
                                    } label: {
                                        HStack {
                                            Text("Page \(match.pages.first?.label ?? "\(idx+1)")")
                                            Spacer()
                                            Text(snippet(for: match))
                                                .lineLimit(1)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } label: {
                                Label("Matches", systemImage: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }

                    Button {
                        if controller.document == nil {
                            presentStandaloneQuickFix()
                        } else {
                            quickFixPresented = true
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .buttonStyle(.plain)
                .help("Run QuickFix on the open document")

                    Button {
                        showEncrypt = true
                    } label: {
                        Image(systemName: "lock.doc")
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.document == nil)
                    .help("Encrypt PDF")

                    if profile.isMassive {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill")
                        }
                        .font(.caption)
                        .padding(6)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .cornerRadius(4)
                        .help("Performance Mode Active")
                    }

                    Button(action: {
                        withAnimation {
                            controller.toggleRightPanel()
                        }
                    }) {
                        Image(systemName: "sidebar.right")
                            .foregroundStyle(controller.isRightPanelVisible ? .blue : .primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.document == nil)
                }
            }
            
            // Layer 2: Centered Switcher
            AppModeSwitcher(currentMode: $selectedTab)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
    
    private var zoomPercentage: String {
        guard let scale = controller.pdfView?.scaleFactor else { return "100%" }
        return "\(Int(scale * 100))%"
    }

    /// One-based page binding for UI while keeping controller zero-based state.
    private var pageBinding: Binding<Int> {
        Binding<Int>(
            get: {
                let count = max((controller.document?.pageCount ?? 1), 1)
                let current = controller.currentPageIndex + 1
                return min(max(current, 1), count)
            },
            set: { newValue in
                let target = max(newValue - 1, 0)
                controller.currentPageIndex = target
                if let page = controller.document?.page(at: target) {
                    controller.pdfView?.go(to: page)
                }
            }
        )
    }

    private func snippet(for selection: PDFSelection) -> String {
        (selection.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(40)
            .replacingOccurrences(of: "\n", with: " ")
    }
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
                        .foregroundStyle(.secondary)
                    Text("No pages yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if selection == 0 {
                    // Thumbnails
                    PDFThumbnailViewRepresentable(pdfView: controller.pdfView ?? PDFView())
                        .background(Color(NSColor.controlBackgroundColor))
                } else {
                    // Outline
                    if let root = controller.document?.outlineRoot {
                        List {
                            OutlineNode(node: root, controller: controller)
                        }
                        .listStyle(.sidebar)
                    } else {
                        VStack {
                            Spacer()
                            Text("No Outline Available")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
        }
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
                .ignoresSafeArea()
        )
    }
}

// Simple Outline View Helper
struct OutlineView: View {
    let root: PDFOutline
    let controller: ReaderControllerPro
    
    var body: some View {
        List {
            OutlineNode(node: root, controller: controller)
        }
    }
}

struct OutlineNode: View {
    let node: PDFOutline
    let controller: ReaderControllerPro
    
    var body: some View {
        let count = node.numberOfChildren
        if count > 0 {
            let children = (0..<count).compactMap { node.child(at: $0) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(children, id: \.self) { child in
                    ReaderOutlineRow(child: child, controller: controller)
                }
            }
        }
    }
}

// MARK: - Visual Effect Helper

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct ReaderOutlineRow: View {
    let child: PDFOutline
    let controller: ReaderControllerPro
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(child.label ?? "Untitled")
                .font(.caption)
                .padding(.leading, CGFloat(child.level) * 10)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let dest = child.destination {
                        controller.pdfView?.go(to: dest)
                    }
                }
            // Recursive call
            OutlineNode(node: child, controller: controller)
        }
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
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}


struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
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
                Text(status)
                    .font(.caption)
            } else {
                Text("Ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if let selection = controller.pdfView?.currentSelection {
                Text("\(selection.pages.count) pages selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(NSColor.windowBackgroundColor))
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
            if controller.document != nil && !profile.isMassive {
                PDFViewProRepresented(document: controller.document) { view in
                    controller.pdfView = view
                }
                .background(Color(NSColor.textBackgroundColor))
            } else if profile.isMassive, let url = controller.currentURL {
                VStack(spacing: 12) {
                    Text("Performance Mode Active")
                        .font(.headline)
                    Text("This document is too large for the full editor.")
                        .foregroundStyle(.secondary)
                    Button("Open in Preview") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                Text("Open a PDF")
                    .foregroundStyle(.secondary)
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
    var didCreate: (PDFView) -> Void
    
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
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

struct PDFThumbnailViewRepresentable: NSViewRepresentable {
    let pdfView: PDFView
    
    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnailView = PDFThumbnailView()
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = CGSize(width: 60, height: 80)

        thumbnailView.backgroundColor = NSColor.controlBackgroundColor
        return thumbnailView
    }
    
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        nsView.pdfView = pdfView
    }
}
