import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct ReaderTabView: View {
    @State private var docURL: URL?
    @State private var pdfDoc: PDFDocument?
    @State private var showOpen = false
    @State private var searchText = ""
    @State private var matches: [PDFSelection] = []
    @State private var currentMatchIndex = 0
    @State private var tool: AnnotationTool = .select
    @State private var showSignaturePad = false
    @State private var signatureImage: NSImage? = SignatureStore.load()
    @State private var manualRedactions: [Int:[CGRect]] = [:]
    @State private var pdfCanvasView: PDFCanvasView?
    @State private var showAlert: Bool = false
    @State private var alertMsg: String = ""
    @State private var debounceWorkItem: DispatchWorkItem?
    @StateObject private var validationRunner = DocumentValidationRunner()
    @State private var isValidating = false
    @State private var validationCompletedPages = 0
    @State private var validationTotalPages = 0
    @State private var validationMode: ValidationMode = .idle
    @State private var isSearching = false
    @State private var searchObservers: [NSObjectProtocol] = []
    @State private var searchToken = UUID()
    @State private var isDocumentLoading = false
    @State private var loadingStatus: String?
    @State private var isQuickFixProcessing = false
    @State private var quickFixStatus: String?
    @State private var quickFixTask: Task<Void, Never>?
    @State private var isLargeDocument = false
    @State private var displayMode: PDFDisplayMode = .singlePageContinuous
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ReaderToolbar(
                    openAction: { openDoc() },
                    saveAsAction: { saveAs() },
                    printAction: { printDoc() },
                    ocrRepairAction: { repairOCR() },
                    applyRedactionsAction: { applyManualRedactions() },
                    validateAction: { validateCurrentDocumentFully() },
                    tool: $tool,
                    showSignaturePad: $showSignaturePad,
                    signatureImage: $signatureImage,
                    validationStatus: validationStatus,
                    isValidateDisabled: isFullValidationInFlight,
                    isQuickFixProcessing: isQuickFixProcessing,
                    quickFixStatus: quickFixStatus
                )
                HStack(spacing: 0) {
                    if let pdfCanvasView, !isLargeDocument {
                        ThumbsSidebar(pdfViewProvider: { pdfCanvasView })
                            .frame(width: 160)
                            .background(.quaternary.opacity(0.1))
                    }
                    VStack(spacing: 0) {
                        ReaderSearchBar(
                            text: $searchText,
                            onSearch: { performSearch() },
                            onPrev: { prevMatch() },
                            onNext: { nextMatch() },
                            status: searchStatus
                        )
                        Divider()
                        ZStack {
                            PDFKitContainerView(
                                pdfDocument: $pdfDoc,
                                tool: $tool,
                                signatureImage: $signatureImage,
                                manualRedactions: $manualRedactions,
                                isLargeDocument: isLargeDocument,
                                displayMode: $displayMode,
                                didCreate: { view in
                                    pdfCanvasView = view
                                }
                            )
                            .contentShape(Rectangle())
                            if isDocumentLoading {
                                ZStack {
                                    Color.black.opacity(0.08)
                                        .ignoresSafeArea()
                                    LoadingOverlayView(status: loadingStatus ?? "Loading…")
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .allowsHitTesting(false)
                            } else if pdfDoc == nil {
                                VStack(spacing: 20) {
                                    Image(systemName: "doc.viewfinder")
                                        .font(.system(size: 64))
                                        .foregroundStyle(AppColors.primary.opacity(0.5))
                                    VStack(spacing: 8) {
                                        Text("No Document Open")
                                            .appFont(.title2, weight: .bold)
                                        Text("Open a PDF to start reading, validating, or editing.")
                                            .appFont(.body)
                                            .foregroundStyle(.secondary)
                                    }
                                    Button("Open PDF…", action: openDoc)
                                        .buttonStyle(PrimaryButtonStyle())
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(AppColors.background)
                            }
                        }
                    }
                }
            }
            FullscreenPDFDropView { url in
                open(url)
            }
        }
        .onChange(of: searchText) { _ in debounceSearch() }
        .fileImporter(isPresented: $showOpen, allowedContentTypes: [.pdf]) { res in
            switch res {
            case .success(let url):
                open(url)
            case .failure(let err):
                self.alert("Open failed: \(err.localizedDescription)")
            }
        }
        .alert("PDF QuickFix Reader", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMsg)
        }
        .onDisappear {
            cancelValidationJob(resetState: true)
            cancelSearch()
            validationRunner.cancelAll()
            isDocumentLoading = false
            loadingStatus = nil
            quickFixTask?.cancel()
        }
    }
    
    private var searchStatus: String {
        if isSearching { return "Searching…" }
        guard !matches.isEmpty else { return "0 results" }
        return "\(currentMatchIndex+1) / \(matches.count)"
    }

    private var validationStatus: String? {
        guard isValidating else { return nil }
        let prefix: String
        switch validationMode {
        case .idle:
            return nil
        case .quick:
            prefix = "Quick check"
        case .full:
            prefix = "Validating"
        }
        guard validationTotalPages > 0 else { return prefix }
        return "\(prefix) \(validationCompletedPages)/\(validationTotalPages)"
    }

    private var isFullValidationInFlight: Bool {
        isValidating && validationMode == .full
    }
    
    private func openDoc() { showOpen = true }
    private func open(_ url: URL) {
        cancelValidationJob(resetState: true)
        cancelSearch()
        validationRunner.cancelOpen()
        isDocumentLoading = true
        loadingStatus = "Opening \(url.lastPathComponent)…"

        validationRunner.openDocument(at: url,
                                      progress: { processed, total in
                                          guard total > 0 else { return }
                                          let clamped = min(processed, total)
                                          self.loadingStatus = "Validating \(clamped)/\(total)"
                                      },
                                      completion: { result in
                                          self.isDocumentLoading = false
                                          self.loadingStatus = nil
                                          switch result {
                                          case .success(let doc):
                                              self.applyOpenedDocument(doc, url: url)
                                          case .failure(let error):
                                              self.docURL = nil
                                              self.pdfDoc = nil
                                              self.alert("Open failed: \(error.localizedDescription)")
                                          }
                                      })
    }

    private func applyOpenedDocument(_ doc: PDFDocument, url: URL) {
        self.docURL = url
        self.pdfDoc = doc
        self.matches = []
        self.currentMatchIndex = 0
        self.manualRedactions.removeAll()
        
        let pageCount = doc.pageCount
        self.isLargeDocument = pageCount > DocumentValidationRunner.largeDocumentPageThreshold
        self.displayMode = self.isLargeDocument ? .singlePage : .singlePageContinuous

        let skipAutoValidation = DocumentValidationRunner.shouldSkipQuickValidation(estimatedPages: nil,
                                                                                   resolvedPageCount: pageCount)
        if !skipAutoValidation {
            scheduleValidation(for: url, pageLimit: 10, mode: .quick)
        }
    }

    private func scheduleValidation(for url: URL, pageLimit: Int?, mode: ValidationMode) {
        validationRunner.cancelValidation()
        validationMode = mode
        validationCompletedPages = 0
        validationTotalPages = pageLimit ?? (pdfDoc?.pageCount ?? 0)
        isValidating = true
        validationRunner.validateDocument(at: url,
                                          pageLimit: pageLimit,
                                          progress: { processed, total in
                                              guard self.docURL == url else { return }
                                              self.validationCompletedPages = processed
                                              self.validationTotalPages = total
                                          },
                                          completion: { result in
                                              guard self.docURL == url else { return }
                                              self.isValidating = false
                                              self.validationMode = .idle
                                              switch result {
                                              case .success:
                                                  break
                                              case .failure(let error):
                                                  if case PDFDocumentSanitizerError.cancelled = error { return }
                                                  self.alert("Validation failed: \(error.localizedDescription)")
                                              }
                                          })
    }

    private func cancelValidationJob(resetState: Bool) {
        validationRunner.cancelValidation()
        if resetState {
            isValidating = false
            validationMode = .idle
            validationCompletedPages = 0
            validationTotalPages = 0
        }
    }

    private func validateCurrentDocumentFully() {
        guard let url = docURL else { alert("Open a PDF first."); return }
        if isFullValidationInFlight { return }
        scheduleValidation(for: url, pageLimit: nil, mode: .full)
    }
    
    private func saveAs() {
        guard let pdfDoc else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (docURL?.deletingPathExtension().lastPathComponent ?? "document") + "-edited.pdf"
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let out = panel.url {
            if pdfDoc.write(to: out) {
                self.alert("Saved to \(out.lastPathComponent)")
                self.docURL = out
            } else {
                self.alert("Save failed.")
            }
        }
    }
    
    private func printDoc() {
        guard let pdfDoc else { return }
        let v = PDFView()
        v.document = pdfDoc
        v.autoScales = true
        let operation = NSPrintOperation(view: v)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }
    
    private func performSearch() {
        matches.removeAll()
        currentMatchIndex = 0
        teardownSearchObservers()
        guard let pdfDoc else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if isLargeDocument && pdfDoc.pageCount >= DocumentValidationRunner.massiveDocumentPageThreshold {
            alert("Search disabled for massive documents (too many pages).")
            return
        }

        isSearching = true
        let token = UUID()
        searchToken = token

        let foundObserver = NotificationCenter.default.addObserver(
            forName: .PDFDocumentDidFindMatch,
            object: pdfDoc,
            queue: .main
        ) { note in
            guard token == self.searchToken else { return }
            guard let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
            self.matches.append(selection)
            if self.matches.count == 1 {
                self.focusMatch(index: 0)
            }
        }

        let endObserver = NotificationCenter.default.addObserver(
            forName: .PDFDocumentDidEndFind,
            object: pdfDoc,
            queue: .main
        ) { _ in
            guard token == self.searchToken else { return }
            self.isSearching = false
            self.teardownSearchObservers()
        }

        searchObservers = [foundObserver, endObserver]
        pdfDoc.cancelFindString()
        pdfDoc.beginFindString(query, withOptions: [.caseInsensitive])
    }

    private func teardownSearchObservers() {
        for observer in searchObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        searchObservers.removeAll()
    }

    private func cancelSearch() {
        pdfDoc?.cancelFindString()
        isSearching = false
        searchToken = UUID()
        teardownSearchObservers()
    }
    
    private func nextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        focusMatch(index: currentMatchIndex)
    }
    private func prevMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        focusMatch(index: currentMatchIndex)
    }
    private func focusMatch(index: Int) {
        guard index >= 0 && index < matches.count else { return }
        if let page = matches[index].pages.first {
            NotificationCenter.default.post(name: .PDFQuickFixJumpToSelection, object: matches[index], userInfo: ["page": page])
        }
    }
    
    private func debounceSearch() {
        debounceWorkItem?.cancel()
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            matches.removeAll()
            currentMatchIndex = 0
            cancelSearch()
            return
        }
        let workItem = DispatchWorkItem { performSearch() }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }
    
    private func repairOCR() {
        performQuickFix(manualRedactions: [:],
                        statusText: "Repairing OCR…",
                        successMessage: "OCR layer added and file cleaned.",
                        failureMessage: "OCR repair failed")
    }

    private func applyManualRedactions() {
        guard !manualRedactions.isEmpty else { alert("No manual redaction boxes were added."); return }
        performQuickFix(manualRedactions: manualRedactions,
                        statusText: "Applying redactions…",
                        successMessage: "Permanent redactions applied.",
                        failureMessage: "Redaction failed")
    }

    private func performQuickFix(manualRedactions: [Int:[CGRect]],
                                 statusText: String,
                                 successMessage: String,
                                 failureMessage: String) {
        guard let url = docURL else { alert("Open a PDF first."); return }
        if isQuickFixProcessing { return }

        let manualCopy = manualRedactions
        quickFixTask?.cancel()
        isQuickFixProcessing = true
        quickFixStatus = statusText

        quickFixTask = Task.detached(priority: .userInitiated) {
            let engine = PDFQuickFixEngine(options: .init(), languages: ["tr-TR","en-US"])
            do {
                let output = try engine.process(inputURL: url,
                                                outputURL: nil,
                                                redactionPatterns: [],
                                                customRegexes: [],
                                                findReplace: [],
                                                manualRedactions: manualCopy)
                await MainActor.run {
                    self.isQuickFixProcessing = false
                    self.quickFixStatus = nil
                    self.quickFixTask = nil
                    self.open(output)
                    self.alert(successMessage)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.isQuickFixProcessing = false
                    self.quickFixStatus = nil
                    self.quickFixTask = nil
                    self.alert("\(failureMessage): \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func alert(_ m: String) { alertMsg = m; showAlert = true }
}

enum AnnotationTool {
    case select
    case note
    case rect
    case highlightSelection
    case stamp
    case redactBox
}

private enum ValidationMode {
    case idle
    case quick
    case full
}

struct ReaderToolbar: View {
    let openAction: () -> Void
    let saveAsAction: () -> Void
    let printAction: () -> Void
    let ocrRepairAction: () -> Void
    let applyRedactionsAction: () -> Void
    let validateAction: () -> Void
    @Binding var tool: AnnotationTool
    @Binding var showSignaturePad: Bool
    @Binding var signatureImage: NSImage?
    let validationStatus: String?
    let isValidateDisabled: Bool
    let isQuickFixProcessing: Bool
    let quickFixStatus: String?
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button(action: openAction) {
                    Label("Open", systemImage: "folder")
                }
                .buttonStyle(GhostButtonStyle())
                
                Button(action: saveAsAction) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(GhostButtonStyle())
                
                Button(action: printAction) {
                    Label("Print", systemImage: "printer")
                }
                .buttonStyle(GhostButtonStyle())
            }
            
            Divider().frame(height: 20)
            
            HStack(spacing: 0) {
                Button(action: ocrRepairAction) {
                    Label("OCR", systemImage: "text.viewfinder")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(isQuickFixProcessing)
                
                Button(action: applyRedactionsAction) {
                    Label("Redact", systemImage: "eye.slash")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(isQuickFixProcessing)
                
                Button(action: validateAction) {
                    Label("Validate", systemImage: "checkmark.shield")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(isValidateDisabled)
            }
            
            Divider().frame(height: 20)
            
            Picker("Tool", selection: $tool) {
                Text("Select").tag(AnnotationTool.select)
                Text("Note").tag(AnnotationTool.note)
                Text("Rectangle").tag(AnnotationTool.rect)
                Text("Highlight").tag(AnnotationTool.highlightSelection)
                Text("Stamp").tag(AnnotationTool.stamp)
                Text("Redact").tag(AnnotationTool.redactBox)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            
            Spacer()
            
            if let validationStatus {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(validationStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(AppColors.surface)
                .cornerRadius(4)
            }
            
            Button(action: { showSignaturePad = true }) {
                Label("Sign", systemImage: "signature")
            }
            .buttonStyle(GhostButtonStyle())
            .popover(isPresented: $showSignaturePad) {
                SignatureCaptureView(image: $signatureImage)
                    .frame(width: 420, height: 260)
                    .padding()
            }
            
            if isQuickFixProcessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(quickFixStatus ?? "Processing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(AppColors.surface)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(AppColors.border),
            alignment: .bottom
        )
    }
}

struct ReaderSearchBar: View {
    @Binding var text: String
    let onSearch: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    var status: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
            TextField("Search in document", text: $text, onCommit: onSearch)
                .textFieldStyle(.roundedBorder)
            Text(status).foregroundStyle(.secondary)
            Button(action: onPrev) { Image(systemName: "chevron.up") }
            Button(action: onNext) { Image(systemName: "chevron.down") }
        }.padding(6)
    }
}

extension Notification.Name {
    static let PDFQuickFixJumpToSelection = Notification.Name("PDFQuickFixJumpToSelection")
}

struct ThumbsSidebar: NSViewRepresentable {
    let pdfViewProvider: () -> PDFView?

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = CGSize(width: 96, height: 128)
        view.maximumNumberOfColumns = 1
        view.pdfView = pdfViewProvider()
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        nsView.pdfView = pdfViewProvider()
    }
}
