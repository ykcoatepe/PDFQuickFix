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
    @State private var showAlert: Bool = false
    @State private var alertMsg: String = ""
    @State private var debounceWorkItem: DispatchWorkItem?
    
    var body: some View {
        VStack(spacing: 0) {
            ReaderToolbar(
                openAction: { openDoc() },
                saveAsAction: { saveAs() },
                printAction: { printDoc() },
                ocrRepairAction: { repairOCR() },
                applyRedactionsAction: { applyManualRedactions() },
                tool: $tool,
                showSignaturePad: $showSignaturePad,
                signatureImage: $signatureImage
            )
            HStack(spacing: 0) {
                if let pdfDoc {
                    ThumbsSidebar(pdfDocument: pdfDoc)
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
                        manualRedactions: $manualRedactions
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
    }
    
    private var searchStatus: String {
        guard !matches.isEmpty else { return "0 results" }
        return "\(currentMatchIndex+1) / \(matches.count)"
    }
    
    private func openDoc() { showOpen = true }
    private func open(_ url: URL) {
        self.docURL = url
        self.pdfDoc = PDFDocument(url: url)
        self.matches = []
        self.currentMatchIndex = 0
        self.manualRedactions.removeAll()
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
        guard let pdfDoc, !searchText.isEmpty else { return }
        let options: NSString.CompareOptions = [.caseInsensitive]
        for index in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: index), let pageString = page.string else { continue }
            let nsString = pageString as NSString
            var searchLocation = 0
            while searchLocation < nsString.length {
                let range = NSRange(location: searchLocation, length: nsString.length - searchLocation)
                let foundRange = nsString.range(of: searchText, options: options, range: range)
                if foundRange.location == NSNotFound { break }
                if let selection = page.selection(for: foundRange) {
                    matches.append(selection)
                }
                searchLocation = foundRange.location + max(foundRange.length, 1)
            }
        }
        if !matches.isEmpty { focusMatch(index: 0) }
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

struct ReaderToolbar: View {
    let openAction: () -> Void
    let saveAsAction: () -> Void
    let printAction: () -> Void
    let ocrRepairAction: () -> Void
    let applyRedactionsAction: () -> Void
    @Binding var tool: AnnotationTool
    @Binding var showSignaturePad: Bool
    @Binding var signatureImage: NSImage?
    
    var body: some View {
        HStack {
            Button("Open…", action: openAction)
            Button("Save As…", action: saveAsAction)
            Button("Print", action: printAction)
            Divider()
            Button("OCR Repair", action: ocrRepairAction)
            Button("Apply Permanent Redactions", action: applyRedactionsAction)
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
        let pdfDocument: PDFDocument
        func makeNSView(context: Context) -> PDFThumbnailView {
            let v = PDFThumbnailView()
            v.thumbnailSize = CGSize(width: 120, height: 160)
            return v
        }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        nsView.pdfView = context.coordinator.pdfView
        nsView.pdfView?.document = pdfDocument
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        let pdfView = PDFView()
    }
}
