import SwiftUI
import PDFKit
import AppKit

// Controller coordinating PDF viewing, search, and page operations.
final class ReaderControllerPro: NSObject, ObservableObject, PDFViewDelegate {
    @Published var document: PDFDocument?
    @Published var currentPageIndex: Int = 0
    @Published var searchQuery: String = ""
    @Published var searchMatches: [PDFSelection] = []
    @Published var isSidebarVisible: Bool = true
    @Published var isProcessing: Bool = false
    @Published var log: String = ""
    
    weak var pdfView: PDFView?
    
    private var findObserver: NSObjectProtocol?
    
    deinit {
        if let observer = findObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    func open(url: URL) {
        document = PDFDocument(url: url)
        pdfView?.document = document
        configurePDFView()
        currentPageIndex = 0
        searchMatches.removeAll()
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
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
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
}

struct ReaderProView: View {
    @StateObject private var controller = ReaderControllerPro()
    @State private var quickFixPresented = false
    @State private var lastOpenedURL: URL?
    
    @State private var showEncrypt = false
    @State private var userPassword = ""
    @State private var ownerPassword = ""
    
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if controller.isSidebarVisible, controller.document != nil {
                    ThumbnailProRepresentedView(pdfViewGetter: { controller.pdfView })
                        .frame(width: 220)
                        .background(.thinMaterial)
                }
                PDFViewProRepresented(document: controller.document) { view in
                    controller.pdfView = view
                }
                .background(Color(NSColor.textBackgroundColor))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                    DispatchQueue.main.async {
                        lastOpenedURL = url
                        controller.open(url: url)
                    }
                }
            }
            return true
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
    
    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                openFile()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a PDF")
            
            Button {
                controller.saveCopy()
            } label: {
                Label("Save Copy", systemImage: "square.and.arrow.down")
            }
            .disabled(controller.document == nil)
            
            Button {
                controller.printDoc()
            } label: {
                Label("Print", systemImage: "printer")
            }
            .disabled(controller.document == nil)
            
            Divider().frame(height: 22)
            
            Button { controller.rotateCurrentPage(left: true) } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .disabled(controller.document == nil)
            
            Button { controller.rotateCurrentPage(left: false) } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .disabled(controller.document == nil)
            
            Button(role: .destructive) { controller.deleteCurrentPage() } label: {
                Label("Delete Page", systemImage: "trash")
            }
            .disabled(controller.document == nil)
            
            Divider().frame(height: 22)
            
            Button { quickFixPresented = true } label: {
                Label("QuickFix…", systemImage: "wand.and.stars")
            }
            .disabled(controller.document == nil)
            .help("Run QuickFix on the open document")
            
            Button { mergePDFs() } label: {
                Label("Merge…", systemImage: "square.on.square")
            }
            
            Button { showEncrypt = true } label: {
                Label("Encrypt…", systemImage: "lock")
            }
            .disabled(controller.document == nil)
            
            Divider().frame(height: 22)
            
            Button {
                controller.applyMark(.highlight, color: NSColor.yellow.withAlphaComponent(0.6))
            } label: {
                Label("Highlight", systemImage: "highlighter")
            }
            .disabled(controller.document == nil)
            
            Button {
                controller.applyMark(.underline, color: NSColor.systemBlue)
            } label: {
                Label("Underline", systemImage: "underline")
            }
            .disabled(controller.document == nil)
            
            Button {
                controller.applyMark(.strikeOut, color: NSColor.systemRed)
            } label: {
                Label("Strike", systemImage: "strikethrough")
            }
            .disabled(controller.document == nil)
            
            Button {
                controller.addStickyNote()
            } label: {
                Label("Note", systemImage: "note.text")
            }
            .disabled(controller.document == nil)
            
            Spacer()
            
            Toggle(isOn: $controller.isSidebarVisible) {
                Image(systemName: "sidebar.leading")
            }
            .toggleStyle(.button)
            .help("Toggle thumbnail sidebar")
            
            HStack(spacing: 6) {
                TextField("Find", text: $controller.searchQuery, onCommit: {
                    controller.find(controller.searchQuery)
                    controller.findNext()
                })
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                
                Button { controller.findPrev() } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                
                Button { controller.findNext() } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let url = panel.url {
            lastOpenedURL = url
            controller.open(url: url)
        }
    }
    
    private func mergePDFs() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK {
            let urls = panel.urls
            guard !urls.isEmpty else { return }
            
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.pdf]
            savePanel.nameFieldStringValue = "Merged.pdf"
            
            if savePanel.runModal() == .OK, let output = savePanel.url {
                do {
                    _ = try PDFMerge.merge(urls: urls, outputURL: output)
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                } catch {
                    print("Merge error: \(error)")
                }
            }
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

// MARK: - PDFView bridge

struct PDFViewProRepresented: NSViewRepresentable {
    var document: PDFDocument?
    var didCreate: (PDFView) -> Void
    
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .textBackgroundColor
        view.document = document
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
        thumbnails.thumbnailSize = NSSize(width: 160, height: 220)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.pdfView = pdfViewGetter()
        return thumbnails
    }
    
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        nsView.pdfView = pdfViewGetter()
    }
}
