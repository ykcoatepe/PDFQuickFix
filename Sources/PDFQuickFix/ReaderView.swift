import SwiftUI
import PDFKit
import AppKit

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
    @State private var sanitizeJob: PDFDocumentSanitizer.Job?
    @State private var isValidating = false
    @State private var validationCompletedPages = 0
    @State private var validationTotalPages = 0
    @State private var validationMode: ValidationMode = .idle
    @State private var isSearching = false
    @State private var searchObservers: [NSObjectProtocol] = []
    @State private var searchToken = UUID()
    
    var body: some View {
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
                isValidateDisabled: isFullValidationInFlight
            )
            HStack(spacing: 0) {
                if let pdfCanvasView {
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
                    PDFKitContainerView(
                        pdfDocument: $pdfDoc,
                        tool: $tool,
                        signatureImage: $signatureImage,
                        manualRedactions: $manualRedactions,
                        didCreate: { view in
                            pdfCanvasView = view
                        }
                    )
                }
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
        do {
            guard let doc = PDFDocument(url: url) else {
                throw PDFDocumentSanitizerError.unableToOpen(url)
            }
            self.docURL = url
            self.pdfDoc = doc
            self.matches = []
            self.currentMatchIndex = 0
            self.manualRedactions.removeAll()
            scheduleValidation(for: url, pageLimit: 10, mode: .quick)
        } catch {
            self.docURL = nil
            self.pdfDoc = nil
            self.alert("Open failed: \(error.localizedDescription)")
        }
    }

    private func scheduleValidation(for url: URL, pageLimit: Int?, mode: ValidationMode) {
        sanitizeJob?.cancel()
        let options = PDFDocumentSanitizer.Options(validationPageLimit: pageLimit)
        validationMode = mode
        validationCompletedPages = 0
        validationTotalPages = pageLimit ?? (pdfDoc?.pageCount ?? 0)
        isValidating = true

        var pendingJob: PDFDocumentSanitizer.Job?
        let job = PDFDocumentSanitizer.loadDocumentAsync(at: url,
                                                         options: options,
                                                         progress: { processed, total in
                                                             guard self.docURL == url else { return }
                                                             self.validationCompletedPages = processed
                                                             self.validationTotalPages = total
                                                         },
                                                         completion: { result in
                                                             guard self.docURL == url else { return }
                                                             if let current = self.sanitizeJob, let pending = pendingJob, current === pending {
                                                                 self.sanitizeJob = nil
                                                             }
                                                             self.isValidating = false
                                                             self.validationMode = .idle
                                                             switch result {
                                                             case .success(let sanitized):
                                                                 self.pdfDoc = sanitized
                                                             case .failure(let error):
                                                                 if case PDFDocumentSanitizerError.cancelled = error { return }
                                                                 self.alert("Validation failed: \(error.localizedDescription)")
                                                             }
                                                         })
        pendingJob = job
        sanitizeJob = job
    }

    private func cancelValidationJob(resetState: Bool) {
        sanitizeJob?.cancel()
        sanitizeJob = nil
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
        guard let url = docURL else { alert("Open a PDF first."); return }
        do {
            let engine = PDFQuickFixEngine(options: .init(), languages: ["tr-TR","en-US"])
            let out = try engine.process(inputURL: url, outputURL: nil, redactionPatterns: [], customRegexes: [], findReplace: [], manualRedactions: [:])
            self.open(out)
            self.alert("OCR layer added and file cleaned.")
        } catch {
            alert("OCR repair failed: \(error.localizedDescription)")
        }
    }
    
    private func applyManualRedactions() {
        guard let url = docURL else { alert("Open a PDF first."); return }
        if manualRedactions.isEmpty { alert("No manual redaction boxes were added."); return }
        do {
            let engine = PDFQuickFixEngine(options: .init(), languages: ["tr-TR","en-US"])
            let out = try engine.process(inputURL: url, outputURL: nil, redactionPatterns: [], customRegexes: [], findReplace: [], manualRedactions: manualRedactions)
            self.open(out)
            self.alert("Permanent redactions applied.")
        } catch {
            alert("Redaction failed: \(error.localizedDescription)")
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
    
    var body: some View {
        HStack {
            Button("Open…", action: openAction)
            Button("Save As…", action: saveAsAction)
            Button("Print", action: printAction)
            Divider()
            Button("OCR Repair", action: ocrRepairAction)
            Button("Apply Permanent Redactions", action: applyRedactionsAction)
            Button("Validate PDF", action: validateAction)
                .disabled(isValidateDisabled)
            Divider()
            Picker("Tool", selection: $tool) {
                Text("Select").tag(AnnotationTool.select)
                Text("Note").tag(AnnotationTool.note)
                Text("Rectangle").tag(AnnotationTool.rect)
                Text("Highlight selection").tag(AnnotationTool.highlightSelection)
                Text("Stamp").tag(AnnotationTool.stamp)
                Text("Redact box").tag(AnnotationTool.redactBox)
            }.pickerStyle(.segmented)
            Spacer()
            if let validationStatus {
                Text(validationStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Signature…") { showSignaturePad = true }
                .popover(isPresented: $showSignaturePad) {
                    SignatureCaptureView(image: $signatureImage)
                        .frame(width: 420, height: 260)
                        .padding()
                }
        }
        .padding(8)
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
        view.thumbnailSize = CGSize(width: 72, height: 108)
        view.maximumNumberOfColumns = 1
        view.pdfView = pdfViewProvider()
        DispatchQueue.main.async {
            guard view.window != nil else { return }
            view.thumbnailSize = CGSize(width: 120, height: 160)
        }
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        nsView.pdfView = pdfViewProvider()
    }
}
