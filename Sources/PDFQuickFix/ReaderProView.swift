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
        guard let doc = document, !text.isEmpty else { return }
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
        }
        
        doc.cancelFindString()
        doc.beginFindString(text, withOptions: [.caseInsensitive])
    }
    
    func focusSelection(_ selection: PDFSelection) {
        selection.color = .yellow.withAlphaComponent(0.35)
        pdfView?.setCurrentSelection(selection, animate: true)
        pdfView?.go(to: selection)
    }
    
    func findNext() {
        guard let view = pdfView, !searchMatches.isEmpty else { return }
        if let current = view.currentSelection,
           let index = searchMatches.firstIndex(of: current),
           index + 1 < searchMatches.count {
            focusSelection(searchMatches[index + 1])
        } else if let first = searchMatches.first {
            focusSelection(first)
        }
    }
    
    func findPrev() {
        guard let view = pdfView, !searchMatches.isEmpty else { return }
        if let current = view.currentSelection,
           let index = searchMatches.firstIndex(of: current),
           index - 1 >= 0 {
            focusSelection(searchMatches[index - 1])
        } else if let last = searchMatches.last {
            focusSelection(last)
        }
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
    @StateObject private var controller = ReaderControllerPro()
    @State private var quickFixPresented = false
    @State private var lastOpenedURL: URL?
    @State private var droppedURL: URL?

    @State private var showEncrypt = false
    @State private var userPassword = ""
    @State private var ownerPassword = ""
    
    var body: some View {
        ReaderShellView(controller: controller,
                        quickFixPresented: $quickFixPresented,
                        showEncrypt: $showEncrypt)
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

// MARK: - Reader Shell View
struct ReaderShellView: View {
    @ObservedObject var controller: ReaderControllerPro
    @Binding var quickFixPresented: Bool
    @Binding var showEncrypt: Bool
    
    // Computed profile based on current document
    private var profile: DocumentProfile {
        if let doc = controller.document {
            return DocumentProfile.from(pageCount: doc.pageCount)
        }
        return .empty
    }
    
    @State private var showRightPanel = false
    
    var body: some View {
        VStack(spacing: 0) {
            ReaderToolbar(controller: controller,
                          profile: profile,
                          quickFixPresented: $quickFixPresented,
                          showEncrypt: $showEncrypt)
            
            HStack(spacing: 0) {
                // Left Sidebar
                if controller.isSidebarVisible {
                    ReaderSidebarLeft(controller: controller, profile: profile)
                        .frame(width: 260)
                        .transition(.move(edge: .leading))
                }
                
                Divider()
                
                // Canvas
                ReaderCanvas(controller: controller, profile: profile)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
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
}

// Extension to support right panel toggle in controller
extension ReaderControllerPro {
    // Add this property to your controller if not present, or use a @Published in the view
    // For now, assuming we add it to the controller or manage it in the view.
    // Since ReaderControllerPro is a class, we can't easily add @Published via extension.
    // Let's assume we modify ReaderControllerPro to include isRightPanelVisible.
    // For this refactor, I will add a computed property wrapper or assume it exists.
    // Actually, let's add it to the controller class definition in the same file if possible,
    // or use a separate state in ShellView if we can't modify the controller easily.
    // But the toolbar needs to toggle it.
    // Let's add it to the controller class in the file.
}


// MARK: - Reader Toolbar
struct ReaderToolbar: View {
    @ObservedObject var controller: ReaderControllerPro
    let profile: DocumentProfile
    @Binding var quickFixPresented: Bool
    @Binding var showEncrypt: Bool
    
    var body: some View {
        HStack(spacing: 16) {
            // ... (keep existing content until button)
            // Left: Back / Title
            HStack(spacing: 8) {
                if let url = controller.currentURL {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("PDFQuickFix")
                        .font(.headline)
                }
            }
            
            Spacer()
            
            // Center: View Controls
            HStack(spacing: 12) {
                // Zoom
                HStack(spacing: 0) {
                    Button(action: { controller.pdfView?.zoomOut(nil) }) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                    
                    Text(zoomPercentage)
                        .font(.caption.monospacedDigit())
                        .frame(width: 48)
                        .multilineTextAlignment(.center)
                    
                    Button(action: { controller.pdfView?.zoomIn(nil) }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                }
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                
                // Page Nav
                HStack(spacing: 4) {
                    Text("Page")
                        .foregroundStyle(.secondary)
                    TextField("Page", value: $controller.currentPageIndex, formatter: NumberFormatter())
                        .textFieldStyle(.plain)
                        .font(.body.monospacedDigit())
                        .multilineTextAlignment(.center)
                        .frame(width: 32)
                        .onSubmit {
                            if let doc = controller.document,
                               let page = doc.page(at: controller.currentPageIndex) {
                                controller.pdfView?.go(to: page)
                            }
                        }
                    Text("/ \(controller.document?.pageCount ?? 0)")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            
            Spacer()
            
            // Right: Tools & Massive Mode Badge
            HStack(spacing: 12) {
                if profile.isMassive {
                    HStack(spacing: 4) {
                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                        Text("Performance Mode")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                    .help("Search and thumbnails are limited for performance.")
                }
                
                if profile.searchEnabled {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Search", text: $controller.searchQuery, onCommit: {
                            controller.find(controller.searchQuery)
                            controller.findNext()
                        })
                        .textFieldStyle(.plain)
                        .frame(width: 120)
                    }
                    .padding(6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }

                Button {
                    quickFixPresented = true
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .buttonStyle(.plain)
                .help("Open QuickFix")

                Button {
                    showEncrypt = true
                } label: {
                    Image(systemName: "lock.doc")
                }
                .buttonStyle(.plain)
                .disabled(controller.document == nil)
                .help("Encrypt PDF")
                
                Button(action: {
                    withAnimation(.sidebarTransition) {
                        controller.toggleRightPanel()
                    }
                }) {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain)
                .help("Toggle Info/Comments")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
    
    private var zoomPercentage: String {
        guard let scale = controller.pdfView?.scaleFactor else { return "100%" }
        return "\(Int(scale * 100))%"
    }
}

// MARK: - Reader Sidebar Left (Pages / Outline)
struct ReaderSidebarLeft: View {
    @ObservedObject var controller: ReaderControllerPro
    let profile: DocumentProfile
    @State private var selection: SidebarTab = .pages
    
    enum SidebarTab { case pages, outline }
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                Image(systemName: "square.grid.2x2").tag(SidebarTab.pages)
                Image(systemName: "list.bullet").tag(SidebarTab.outline)
            }
            .pickerStyle(.segmented)
            .padding(8)
            
            Divider()
            
            if selection == .pages {
                if profile.thumbnailsEnabled {
                    ThumbnailProRepresentedView(pdfViewGetter: { controller.pdfView })
                } else {
                    List(0..<(controller.document?.pageCount ?? 0), id: \.self) { index in
                        Text("Page \(index + 1)")
                            .font(.caption)
                            .onTapGesture {
                                if let page = controller.document?.page(at: index) {
                                    controller.pdfView?.go(to: page)
                                }
                            }
                    }
                }
            } else {
                if profile.outlineEnabled {
                    if let outline = controller.document?.outlineRoot {
                        OutlineView(root: outline, controller: controller)
                    } else {
                        Text("No Outline")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    Text("Outline disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
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
            // TODO: Fix OutlineNode recursion
            Text("Outline Children Placeholder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
        }
    }
}


// MARK: - Reader Sidebar Right (Comments / Info)
struct ReaderSidebarRight: View {
    @ObservedObject var controller: ReaderControllerPro
    let profile: DocumentProfile
    @State private var selection: RightPanelTab = .info
    
    enum RightPanelTab { case comments, info }
    
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                Text("Info").tag(RightPanelTab.info)
                Text("Comments").tag(RightPanelTab.comments)
            }
            .pickerStyle(.segmented)
            .padding(8)
            
            Divider()
            
            if selection == .info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(label: "File", value: controller.currentURL?.lastPathComponent ?? "-")
                        InfoRow(label: "Pages", value: "\(controller.document?.pageCount ?? 0)")
                        InfoRow(label: "Size", value: "Calculating...") // Placeholder
                        InfoRow(label: "Security", value: controller.document?.isEncrypted == true ? "Encrypted" : "None")
                        
                        Divider()
                        
                        if let status = controller.validationStatus {
                            Text("Validation")
                                .font(.headline)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
            } else {
                if profile.globalAnnotationsEnabled {
                    Text("Comments List Placeholder")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Comments disabled for performance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
