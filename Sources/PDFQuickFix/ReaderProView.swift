import AppKit
import os.log
@preconcurrency import PDFKit
@preconcurrency import PDFQuickFixKit
import SwiftUI
import UniformTypeIdentifiers

/// Controller coordinating PDF viewing, search, and page operations.
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
    @Published var selectedRightPanelTab: ReaderRightPanelTab = .info
    @Published var isProcessing: Bool = false
    @Published var copilotQuery: String = ""
    @Published var copilotResponse: DocumentCopilotResponse?
    @Published var copilotError: String?
    @Published var isCopilotRunning: Bool = false
    @Published var outlineRows: [OutlineRow] = []
    @Published var hasLoadedOutline: Bool = false
    @Published var isOutlineTruncated: Bool = false
    @Published var outlineResetToken: Int = 0
    @Published var annotationRows: [AnnotationRow] = []

    func toggleRightPanel() {
        isRightPanelVisible.toggle()
    }

    @Published var log: String = ""
    @Published var validationStatus: String?
    @Published var isFullValidationRunning: Bool = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var sourceURL: URL?
    private var activeSecurityScope: SecurityScopedAccess?
    @Published var isLoadingDocument: Bool = false
    @Published var loadingStatus: String?
    @Published var isLargeDocument: Bool = false
    @Published var isMassiveDocument: Bool = false
    @Published var isPartialLoad: Bool = false
    @Published var isRepaired: Bool = false
    @Published var skippedQuickValidation: Bool = false
    private var requiresUnlockedValidation: Bool = false
    @Published var isDocumentHealthPresented: Bool = false
    @Published private(set) var currentSelectionTextState: String?

    weak var pdfView: PDFView? {
        didSet {
            rebindPDFViewObservers(from: oldValue, to: pdfView)
            refreshSelectionState()
        }
    }

    var currentSelectionText: String? {
        currentSelectionTextState ?? normalizedSelectionText(from: pdfView?.currentSelection)
    }

    var canReplaceSelectedText: Bool {
        currentSelectionText != nil
    }

    private var findObserver: NSObjectProtocol?
    private var selectionObserver: NSObjectProtocol?
    private let validationRunner = DocumentValidationRunner()
    private var copilotService: any DocumentCopilotServicing
    private let usesCustomCopilotService: Bool
    private let passwordProvider: PDFPasswordProvider
    private weak var aiSettings: LocalAISettings?
    private var searchDebounceWorkItem: DispatchWorkItem?
    private var activeCopilotRequestID: UInt64 = 0
    private enum ValidationMode { case idle, quick, full }
    private var validationMode: ValidationMode = .idle
    private let largeDocumentPageThreshold = DocumentValidationRunner.largeDocumentPageThreshold
    private let editUndoManager = UndoManager()

    init(copilotService: (any DocumentCopilotServicing)? = nil,
         passwordProvider: @escaping PDFPasswordProvider = PDFPasswordPrompt.requestPassword)
    {
        self.copilotService = copilotService ?? DocumentCopilotService(interactionStore: AIInteractionStore())
        usesCustomCopilotService = copilotService != nil
        self.passwordProvider = passwordProvider
        super.init()
    }

    deinit {
        if let observer = findObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = selectionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        validationRunner.cancelAll()
    }

    func open(url: URL, access: SecurityScopedAccess? = nil) {
        validationRunner.cancelValidation()
        validationRunner.cancelOpen()
        let effectiveAccess = access ?? SecurityScopedAccess(url: url)
        isLoadingDocument = true
        loadingStatus = "Opening \(url.lastPathComponent)…"
        let readerOpenSP = PerfLog.begin("ReaderOpen")
        let openStart = Date()

        let massiveThreshold = DocumentValidationRunner.massiveDocumentPageThreshold

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            if let encryptedDoc = PDFDocument(url: url), encryptedDoc.isEncrypted, encryptedDoc.isLocked {
                DispatchQueue.main.async {
                    self.finishEncryptedOpen(document: encryptedDoc,
                                             sourceURL: url,
                                             workingURL: url,
                                             access: effectiveAccess,
                                             isRepaired: false,
                                             signpostID: readerOpenSP,
                                             openStart: openStart)
                }
                return
            }

            // Repair/Normalize if needed
            var finalURL = url
            var repaired = false
            do {
                let repairedURL = try PDFRepairService().repairIfNeeded(inputURL: url)
                if repairedURL != url {
                    finalURL = repairedURL
                    repaired = true
                }
            } catch {
                // Fallback to original is automatic if repairIfNeeded throws or returns original
                // But repairIfNeeded is designed to not throw for fallback cases, so this catch might be rare
                print("Reader repair failed: \(error)")
            }

            guard let rawDoc = PDFDocument(url: finalURL) else {
                DispatchQueue.main.async {
                    self.isLoadingDocument = false
                    self.loadingStatus = nil
                    self.handleOpenError(PDFDocumentSanitizerError.unableToOpen(url))
                    PerfLog.end("ReaderOpen", readerOpenSP)
                }
                return
            }

            if rawDoc.isEncrypted, rawDoc.isLocked {
                DispatchQueue.main.async {
                    self.finishEncryptedOpen(document: rawDoc,
                                             sourceURL: url,
                                             workingURL: finalURL,
                                             access: effectiveAccess,
                                             isRepaired: repaired,
                                             signpostID: readerOpenSP,
                                             openStart: openStart)
                }
                return
            }

            let pageCount = rawDoc.pageCount
            let isMassive = pageCount >= massiveThreshold

            if isMassive {
                DispatchQueue.main.async {
                    self.loadingStatus = nil
                    self.isLoadingDocument = false
                    self.finishOpen(document: rawDoc, sourceURL: url, workingURL: finalURL, access: effectiveAccess, isRepaired: repaired)
                    #if DEBUG
                        let duration = Date().timeIntervalSince(openStart)
                        PerfMetrics.shared.recordReaderOpen(duration: duration)
                    #endif
                    PerfLog.end("ReaderOpen", readerOpenSP)
                }
            } else {
                DispatchQueue.main.async {
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
                                                           isLoadingDocument = false
                                                           loadingStatus = nil
                                                           switch result {
                                                           case let .success(doc):
                                                               finishOpen(document: doc, sourceURL: url, workingURL: finalURL, access: effectiveAccess, isRepaired: repaired)
                                                               #if DEBUG
                                                                   let duration = Date().timeIntervalSince(openStart)
                                                                   PerfMetrics.shared.recordReaderOpen(duration: duration)
                                                               #endif
                                                               PerfLog.end("ReaderOpen", readerOpenSP)
                                                           case let .failure(error):
                                                               handleOpenError(error)
                                                               PerfLog.end("ReaderOpen", readerOpenSP)
                                                           }
                                                       })
                }
            }
        }
    }

    private func finishEncryptedOpen(document rawDoc: PDFDocument,
                                     sourceURL: URL,
                                     workingURL: URL,
                                     access: SecurityScopedAccess?,
                                     isRepaired: Bool,
                                     signpostID: OSSignpostID,
                                     openStart: Date)
    {
        loadingStatus = "Unlocking \(sourceURL.lastPathComponent)…"
        guard PDFPasswordUnlock.unlockIfNeeded(document: rawDoc, url: sourceURL, passwordProvider: passwordProvider) else {
            resetDocumentState()
            log = "Open failed: password required for \(sourceURL.lastPathComponent)"
            PerfLog.end("ReaderOpen", signpostID)
            return
        }

        isLoadingDocument = false
        loadingStatus = nil
        finishOpen(document: rawDoc,
                   sourceURL: sourceURL,
                   workingURL: workingURL,
                   access: access,
                   isRepaired: isRepaired,
                   requiresUnlockedValidation: true)
        #if DEBUG
            let duration = Date().timeIntervalSince(openStart)
            PerfMetrics.shared.recordReaderOpen(duration: duration)
        #endif
        PerfLog.end("ReaderOpen", signpostID)
    }

    private func finishOpen(document newDocument: PDFDocument,
                            sourceURL: URL,
                            workingURL: URL,
                            access: SecurityScopedAccess?,
                            isRepaired: Bool = false,
                            requiresUnlockedValidation: Bool = false)
    {
        let sp = PerfLog.begin("ReaderApplyDocument")
        defer { PerfLog.end("ReaderApplyDocument", sp) }
        currentURL = workingURL
        self.sourceURL = sourceURL
        activeSecurityScope = access
        clearEditUndoStacks()
        document = newDocument

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: workingURL.path)[.size] as? Int64) ?? 0
        let profile = DocumentProfile.from(pageCount: newDocument.pageCount, fileSizeBytes: fileSize)
        isLargeDocument = profile.isLarge
        isMassiveDocument = profile.isMassive
        if isMassiveDocument {
            logMassiveDocument(pageCount: newDocument.pageCount, url: workingURL)
        }

        if !isMassiveDocument {
            pdfView?.document = newDocument
            configurePDFView()
        } else {
            // Massive docs: still display but with performance optimizations
            pdfView?.document = newDocument
            pdfView?.displayMode = .singlePage
            pdfView?.displaysPageBreaks = false
            pdfView?.autoScales = true
            refreshSelectionState()
        }
        currentPageIndex = 0
        searchMatches.removeAll()
        invalidateOutlineCache()
        refreshAnnotationsForReader()
        validationStatus = nil
        validationMode = .idle
        isFullValidationRunning = false
        isPartialLoad = false
        self.isRepaired = isRepaired
        self.requiresUnlockedValidation = requiresUnlockedValidation
        clearCopilotOutput()

        let shouldSkipAutoValidation = DocumentValidationRunner.shouldSkipQuickValidation(
            estimatedPages: nil,
            resolvedPageCount: newDocument.pageCount
        ) || requiresUnlockedValidation
        skippedQuickValidation = shouldSkipAutoValidation
        let isMassive = profile.isMassive
        if !isMassive, !shouldSkipAutoValidation {
            scheduleValidation(for: workingURL, pageLimit: 10, mode: .quick)
        }

        // Add to Recent Files
        DispatchQueue.main.async {
            RecentFilesManager.shared.add(url: sourceURL, pageCount: newDocument.pageCount)
            NotificationCenter.default.post(name: .readerDidOpenDocument, object: sourceURL)
        }
    }

    private func handleOpenError(_ error: Error) {
        resetDocumentState()
        log = "❌ \(error.localizedDescription)"
        present(error)
    }

    func validateFully() {
        guard let url = currentURL, !isFullValidationRunning else { return }
        guard !requiresUnlockedValidation else {
            skippedQuickValidation = true
            validationMode = .idle
            isFullValidationRunning = false
            validationStatus = nil
            log = "Full validation skipped for encrypted PDF. Export an unlocked, sanitized copy before validating."
            return
        }
        scheduleValidation(for: url, pageLimit: nil, mode: .full)
    }

    /// Closes the current document and resets all state.
    func closeDocument() {
        resetDocumentState(clearLog: true)
    }

    private func resetDocumentState(clearLog: Bool = false) {
        validationRunner.cancelOpen()
        validationRunner.cancelValidation()
        isLoadingDocument = false
        loadingStatus = nil
        clearEditUndoStacks()
        document = nil
        pdfView?.document = nil
        currentURL = nil
        sourceURL = nil
        activeSecurityScope = nil
        isLargeDocument = false
        isMassiveDocument = false
        isPartialLoad = false
        isRepaired = false
        skippedQuickValidation = false
        requiresUnlockedValidation = false
        searchMatches.removeAll()
        currentMatchIndex = nil
        invalidateOutlineCache()
        validationStatus = nil
        isFullValidationRunning = false
        validationMode = .idle
        if clearLog {
            log = ""
        }
        currentSelectionTextState = nil
        annotationRows = []
        clearCopilotOutput()
    }

    private func clearEditUndoStacks() {
        pdfView?.undoManager?.removeAllActions()
        editUndoManager.removeAllActions()
    }

    func saveAs() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-copy.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            if writeDocument(doc, to: url) {
                currentURL = url
                sourceURL = url
                log = "Saved as \(url.lastPathComponent)"
            } else if !log.contains("Save blocked") {
                log = "Save As failed: \(url.lastPathComponent)"
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
            log = "Saved \(url.lastPathComponent)"
        } else if !log.contains("Save blocked") {
            log = "Save failed: \(url.lastPathComponent)"
        }
    }

    private func writeDocument(_ doc: PDFDocument, to url: URL) -> Bool {
        guard PDFOps.containsReplacementTextAnnotations(in: doc) else {
            return doc.write(to: url)
        }
        guard !doc.isEncrypted else {
            log = "Save blocked: export an encrypted copy after replacing text in a protected PDF."
            return false
        }

        do {
            let data = try PDFOps.flattenedData(document: doc)
            try data.write(to: url, options: .atomic)
            guard let flattened = PDFDocument(data: data) else {
                throw PDFOpsError.saveFailed
            }
            document = flattened
            pdfView?.document = flattened
            currentSelectionTextState = nil
            clearEditUndoStacks()
            invalidateOutlineCache()
            refreshAnnotationsForReader(includeMassiveDocument: true)
            return true
        } catch {
            log = "Save failed: \(error.localizedDescription)"
            present(error)
            return false
        }
    }

    func repairAndSaveAs() {
        guard let url = currentURL else { return }

        isProcessing = true
        loadingStatus = "Normalizing document..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let service = PDFRepairService()
                let repairedURL = try service.repairForExport(inputURL: url)

                DispatchQueue.main.async {
                    self.isProcessing = false
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
                            // Optional: Ask to open? For now just notify or do nothing.
                            // Maybe show in Finder
                            NSWorkspace.shared.activateFileViewerSelecting([destination])
                        } catch {
                            self.present(error)
                        }
                    } else {
                        // Cleanup temp file if cancelled
                        try? FileManager.default.removeItem(at: repairedURL)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.loadingStatus = nil
                    self.present(error)
                }
            }
        }
    }

    func exportToImages(format: NSBitmapImageRep.FileType) {
        guard let doc = document else {
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
            let snapshot: Data
            do {
                snapshot = try imageExportSnapshotData()
            } catch {
                log = "Export failed: \(error.localizedDescription)"
                present(error)
                return
            }

            let fileExtension = switch format {
            case .jpeg: "jpg"
            case .png: "png"
            case .tiff: "tiff"
            default: "img"
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

                for i in 0 ..< backgroundDoc.pageCount {
                    guard let page = backgroundDoc.page(at: i) else { continue }
                    let pageRect = page.bounds(for: .mediaBox)
                    // Use PDFPage.thumbnail to generate image

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

                Task { @MainActor [weak self] in
                    self?.isProcessing = false
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

    func exportToText() {
        guard let doc = document else {
            log = "Export failed: couldn't read current document state"
            return
        }
        guard !PDFOps.containsReplacementTextAnnotations(in: doc) else {
            log = "Export blocked: Text export is blocked after Replace Text or Redact Text because the original text layer may still be extractable. Export a sanitized or flattened PDF copy instead."
            return
        }
        guard !doc.isEncrypted else {
            log = "Export blocked: Text export is blocked for encrypted PDFs. Export a flattened or sanitized copy first."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Document") + ".txt"

        if panel.runModal() == .OK, let url = panel.url {
            isProcessing = true
            guard let snapshotData = doc.dataRepresentation() else {
                isProcessing = false
                log = "Export failed: couldn't snapshot current document state"
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    guard let snapshot = PDFDocument(data: snapshotData) else {
                        throw PDFOpsError.missingDocument
                    }
                    let fullText = try PDFOps.extractTextForExport(document: snapshot)
                    try fullText.write(to: url, atomically: true, encoding: .utf8)

                    Task { @MainActor [weak self] in
                        self?.isProcessing = false
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.isProcessing = false
                        self?.log = "Export failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    var hasPrintableDocument: Bool {
        document != nil
    }

    func printDocument() {
        _ = DocumentPrintService.print(document: document,
                                       jobTitle: document?.documentURL?.lastPathComponent ?? "PDFQuickFix",
                                       source: "reader")
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
        // PDFKit's beginFindString is asynchronous and fires per-match notifications,
        // so it's safe to run on massive documents without freezing the UI.

        findObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        findObserver = nil
        findObserver = NotificationCenter.default.addObserver(
            forName: .PDFDocumentDidFindMatch,
            object: doc,
            queue: .main
        ) { [weak self] note in
            guard let selection = note.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                searchMatches.append(selection)
                if let idx = searchMatches.indices.last, currentMatchIndex == nil {
                    focusSelection(selection, at: idx)
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
        let nextIndex: Int = if let current = currentMatchIndex {
            (current + 1) % searchMatches.count
        } else {
            0
        }
        focusSelection(searchMatches[nextIndex], at: nextIndex)
    }

    func findPrev() {
        guard !searchMatches.isEmpty else { return }
        let prevIndex: Int = if let current = currentMatchIndex {
            (current - 1 + searchMatches.count) % searchMatches.count
        } else {
            max(searchMatches.count - 1, 0)
        }
        focusSelection(searchMatches[prevIndex], at: prevIndex)
    }

    // MARK: - Annotations

    func applyMark(_ subtype: PDFAnnotationSubtype, color: NSColor) {
        guard let view = pdfView, let selection = view.currentSelection else { return }
        var additions: [PDFAnnotation] = []
        for page in selection.pages {
            let rects = annotationRects(for: selection, on: page)
            for rect in rects {
                let annotation = PDFAnnotation(bounds: rect, forType: subtype, withProperties: nil)
                annotation.color = color
                page.addAnnotation(annotation)
                additions.append(annotation)
            }
        }
        registerAnnotationAdditions(additions, actionName: "Add Markup")
        refreshAnnotationsForReader()
    }

    func replaceSelectedText(with replacement: String) {
        guard let view = pdfView, let selection = view.currentSelection else { return }
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
        refreshAnnotationsForReader()
    }

    func redactSelectedText() {
        guard let view = pdfView, let selection = view.currentSelection else { return }

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
        refreshAnnotationsForReader()
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

    func addStickyNote() {
        guard let page = pdfView?.currentPage else { return }
        let bounds = page.bounds(for: .mediaBox)
        let noteBounds = CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)
        let note = PDFAnnotation(bounds: noteBounds, forType: .text, withProperties: nil)
        note.iconType = .note
        note.contents = "Note"
        page.addAnnotation(note)
        registerAnnotationAddition(note, actionName: "Add Note")
        refreshAnnotationsForReader()
    }

    func loadAnnotationsForReader(force: Bool = false) {
        if isMassiveDocument, !force {
            annotationRows = []
            return
        }
        refreshAnnotationsForReader(includeMassiveDocument: force)
    }

    func loadOutlineIfNeeded() {
        guard !hasLoadedOutline else { return }
        let limit = isMassiveDocument ? PDFOutlineLoader.massiveDocumentRowLimit : nil
        let result = PDFOutlineLoader.rows(from: document?.outlineRoot, limit: limit)
        outlineRows = result.rows
        isOutlineTruncated = result.isTruncated
        hasLoadedOutline = true
    }

    func invalidateOutlineCache() {
        outlineRows = []
        hasLoadedOutline = false
        isOutlineTruncated = false
        outlineResetToken &+= 1
    }

    func focus(annotation row: AnnotationRow) {
        guard let page = row.annotation.page else { return }
        let bounds = row.annotation.bounds
        let destination = PDFDestination(page: page, at: CGPoint(x: bounds.midX, y: bounds.midY))
        pdfView?.go(to: destination)
        if let document {
            let index = document.index(for: page)
            if index >= 0 {
                currentPageIndex = index
            }
        }
    }

    func delete(annotation row: AnnotationRow) {
        guard let page = row.annotation.page else { return }
        registerAnnotationRemoval(row.annotation, on: page, actionName: "Delete Annotation")
        page.removeAnnotation(row.annotation)
        refreshAnnotationsForReader()
    }

    func editAnnotation(_ row: AnnotationRow, contents: String) {
        editAnnotation(row, draft: AnnotationEditDraft(contents: contents, urlString: nil))
    }

    func editAnnotation(_ row: AnnotationRow, draft: AnnotationEditDraft) {
        let annotation = row.annotation
        let oldContents = annotation.contents
        let newContents = PDFStringNormalizer.normalizedNonEmpty(draft.contents, context: "annotation contents")
        let oldURL = annotation.url
        let newURL = draft.urlString.flatMap(Self.annotationURL)
        guard oldContents != newContents || oldURL != newURL else { return }
        registerAnnotationEditUndo(annotation: annotation,
                                   oldContents: oldContents,
                                   oldURL: oldURL,
                                   newContents: newContents,
                                   newURL: newURL)
        annotation.contents = newContents
        if draft.urlString != nil {
            annotation.url = newURL
        }
        refreshAnnotationsForReader()
    }

    func loadPartialDocument(pageLimit: Int = 50) {
        guard let originalDoc = document else { return }
        let partialDoc = PDFDocument()
        let count = min(originalDoc.pageCount, pageLimit)

        for i in 0 ..< count {
            guard let page = originalDoc.page(at: i),
                  let copy = page.copy() as? PDFPage else { continue }
            partialDoc.insert(copy, at: i)
        }

        pdfView?.document = partialDoc
        configurePDFView()
        isMassiveDocument = false // Temporarily treat as normal for viewing
        isPartialLoad = true

        // Notify user
        log = "Loaded first \(count) pages for preview."
    }

    func loadFullDocument() {
        guard let originalDoc = document else { return }

        // Re-evaluate profile to restore massive state if needed
        let profile = DocumentProfile.from(pageCount: originalDoc.pageCount)
        isMassiveDocument = profile.isMassive
        isPartialLoad = false

        // If it was massive, we are now "forcing" it to load fully?
        // Or should we just return to the massive placeholder?
        // The user clicked "Load All", so we should try to load it into the view.
        // We will set isMassiveDocument = false to allow the view to render it,
        // but we might want to warn or keep some flags.
        // For now, let's allow it but maybe keep isLargeDocument = true for tuning.

        // Actually, if we set isMassiveDocument = false, the view will try to render.
        // Let's do that, assuming the user knows what they are doing.
        isMassiveDocument = false

        pdfView?.document = originalDoc
        configurePDFView()

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

    func undoLastEdit() {
        activeUndoManager.undo()
    }

    func redoLastEdit() {
        activeUndoManager.redo()
    }

    private var currentPDFPage: PDFPage? {
        if let pdfView, let page = pdfView.currentPage {
            return page
        }
        return nil
    }

    private var activeUndoManager: UndoManager {
        pdfView?.undoManager ?? editUndoManager
    }

    private func notifyPageRotationChanged() {
        // PDFKit repaints automatically, but we can force a layout update if needed.
        // For now, this is a placeholder for any side effects.
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

    private func registerAnnotationAddition(_ annotation: PDFAnnotation, actionName: String) {
        guard let page = annotation.page else { return }
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            page.removeAnnotation(annotation)
            target.refreshAnnotationsForReader()
            target.registerAnnotationRemoval(annotation, on: page, actionName: actionName)
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
                page.removeAnnotation(annotation)
            }
            target.refreshAnnotationsForReader()
            target.registerAnnotationRemovals(entries, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerAnnotationRemoval(_ annotation: PDFAnnotation, on page: PDFPage, actionName: String) {
        registerAnnotationRemovals([(annotation, page)], actionName: actionName)
    }

    private func registerAnnotationRemovals(_ entries: [(PDFAnnotation, PDFPage)], actionName: String) {
        guard !entries.isEmpty else { return }
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            for (annotation, page) in entries {
                page.addAnnotation(annotation)
            }
            target.refreshAnnotationsForReader()
            target.registerAnnotationAdditions(entries.map { $0.0 }, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
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
            target.refreshAnnotationsForReader()
            target.registerAnnotationEditUndo(annotation: annotation,
                                              oldContents: newContents,
                                              oldURL: newURL,
                                              newContents: oldContents,
                                              newURL: oldURL)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName("Edit Annotation")
        }
    }

    private static func annotationURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    func deleteCurrentPage() {
        guard let doc = document, let page = pdfView?.currentPage else { return }
        let index = doc.index(for: page)
        guard index >= 0, index < doc.pageCount else { return }
        registerPageDeletionUndo(page: page, index: index, actionName: "Delete Page")
        doc.removePage(at: index)
        currentPageIndex = min(index, max(doc.pageCount - 1, 0))
        if let nextPage = doc.page(at: currentPageIndex) {
            pdfView?.go(to: nextPage)
        }
        refreshAnnotationsForReader()
    }

    private func registerPageDeletionUndo(page: PDFPage, index: Int, actionName: String) {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            guard let doc = target.document else { return }
            let restoredIndex = max(0, min(index, doc.pageCount))
            doc.insert(page, at: restoredIndex)
            target.currentPageIndex = restoredIndex
            target.pdfView?.go(to: page)
            target.refreshAnnotationsForReader()
            target.registerPageInsertionUndo(page: page, index: restoredIndex, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
    }

    private func registerPageInsertionUndo(page: PDFPage, index: Int, actionName: String) {
        let undoManager = activeUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            guard let doc = target.document else { return }
            let currentIndex = doc.index(for: page)
            guard currentIndex >= 0, currentIndex < doc.pageCount else { return }
            doc.removePage(at: currentIndex)
            target.currentPageIndex = min(currentIndex, max(doc.pageCount - 1, 0))
            if let nextPage = doc.page(at: target.currentPageIndex) {
                target.pdfView?.go(to: nextPage)
            }
            target.refreshAnnotationsForReader()
            target.registerPageDeletionUndo(page: page, index: index, actionName: actionName)
        }
        if !undoManager.isUndoing {
            undoManager.setActionName(actionName)
        }
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

    func runCopilotQuery() async {
        let query = copilotQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            copilotError = "Enter a question first."
            return
        }
        await runCopilotRequest(.ask(question: query, scope: .document))
    }

    func runCopilotRequest(_ request: DocumentCopilotRequest) async {
        guard let session = makeCopilotSession() else {
            copilotError = PDFTextExtractorError.missingInput.localizedDescription
            return
        }

        let modelName = currentCopilotModelName()
        activeCopilotRequestID &+= 1
        let requestID = activeCopilotRequestID
        isCopilotRunning = true
        copilotError = nil
        copilotResponse = nil

        do {
            let response = try await copilotService.respond(
                to: request,
                using: session,
                sourceName: currentURL?.lastPathComponent ?? document?.documentURL?.lastPathComponent,
                modelName: modelName
            )
            guard requestID == activeCopilotRequestID else { return }
            copilotResponse = response
        } catch {
            guard requestID == activeCopilotRequestID else { return }
            copilotError = error.localizedDescription
        }

        guard requestID == activeCopilotRequestID else { return }
        isCopilotRunning = false
    }

    func explainCurrentSelection() async {
        guard let selectionText = currentSelectionText else {
            copilotError = "Select text first."
            return
        }
        await runCopilotRequest(.explainSelection(selection: selectionText, scope: .selection(selectionText)))
    }

    func runCurrentPageDigest() async {
        let pageIndex = currentDisplayedPageIndex() ?? currentPageIndex
        await runCopilotRequest(.currentPageDigest(scope: .currentPage(index: pageIndex)))
    }

    func jumpToCitationPage(_ citation: DocumentCopilotCitation) {
        guard let document, citation.pageIndex >= 0, let page = document.page(at: citation.pageIndex) else { return }
        pdfView?.go(to: page)
        currentPageIndex = citation.pageIndex
    }

    func configureCopilotInteractionStore(_ interactionStore: AIInteractionStore) {
        guard !usesCustomCopilotService else { return }
        copilotService = DocumentCopilotService(interactionStore: interactionStore)
    }

    func configureCopilotAI(settings: LocalAISettings, interactionStore: AIInteractionStore) {
        guard !usesCustomCopilotService else { return }
        aiSettings = settings
        copilotService = DocumentCopilotService(
            interactionStore: interactionStore,
            client: settings.makeTextClient()
        )
    }

    // MARK: - Helpers

    private func configurePDFView() {
        guard let view = pdfView else { return }
        view.applyPerformanceTuning(isLargeDocument: isLargeDocument,
                                    desiredDisplayMode: .singlePageContinuous,
                                    resetScale: true)
        view.delegate = self
        zoomScale = view.scaleFactor
        refreshSelectionState()
    }

    private func makeCopilotSession() -> DocumentTextSession? {
        if let document {
            return DocumentTextSession(document: document)
        }
        guard let url = currentURL else { return nil }
        return try? DocumentTextSession(documentURL: url)
    }

    private func refreshAnnotationsForReader(includeMassiveDocument: Bool = false) {
        guard let document, includeMassiveDocument || !isMassiveDocument else {
            annotationRows = []
            return
        }
        var rows: [AnnotationRow] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                rows.append(AnnotationRow(annotation: annotation, pageIndex: index))
            }
        }
        annotationRows = rows
    }

    private func currentCopilotModelName() -> String? {
        let modelName = (aiSettings?.defaultModel ?? LocalAISettings().defaultModel).trimmingCharacters(in: .whitespacesAndNewlines)
        return modelName.isEmpty ? nil : modelName
    }

    private func clearCopilotOutput() {
        activeCopilotRequestID &+= 1
        copilotResponse = nil
        copilotError = nil
        isCopilotRunning = false
    }

    private func normalizedSelectionText(from selection: PDFSelection?) -> String? {
        guard let value = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func refreshSelectionState() {
        let selectionText = normalizedSelectionText(from: pdfView?.currentSelection)
        guard currentSelectionTextState != selectionText else { return }
        currentSelectionTextState = selectionText
    }

    fileprivate func handlePDFSelectionChange() {
        refreshSelectionState()
    }

    private func rebindPDFViewObservers(from _: PDFView?, to newValue: PDFView?) {
        if let observer = selectionObserver {
            NotificationCenter.default.removeObserver(observer)
            selectionObserver = nil
        }

        guard let newValue else { return }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged,
            object: newValue,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSelectionState()
            }
        }
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
                                              guard let self, currentURL == url else { return }
                                              updateValidationStatus(processed: processed, total: total)
                                          },
                                          completion: { [weak self] result in
                                              guard let self, currentURL == url else { return }
                                              validationMode = .idle
                                              isFullValidationRunning = false
                                              validationStatus = nil
                                              switch result {
                                              case .success:
                                                  currentPageIndex = currentDisplayedPageIndex() ?? currentPageIndex
                                                  searchMatches.removeAll()
                                              case let .failure(error):
                                                  if case PDFDocumentSanitizerError.cancelled = error { return }
                                                  log = "❌ \(error.localizedDescription)"
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

    private func logMassiveDocument(pageCount: Int, url: URL?) {
        NSLog("PDFPerfTelemetry: massiveDocEnabled pageCount=%d file=%@", pageCount, url?.lastPathComponent ?? "unknown")
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
        let name = currentURL?.lastPathComponent ?? document.documentURL?.lastPathComponent ?? "PDF"
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
}

enum ReaderRightPanelTab: String, CaseIterable, Identifiable {
    case info
    case comments
    case copilot

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .info:
            "Info"
        case .comments:
            "Comments"
        case .copilot:
            "Copilot"
        }
    }

    var symbolName: String {
        switch self {
        case .info:
            "info.circle"
        case .comments:
            "text.bubble"
        case .copilot:
            "sparkles"
        }
    }
}

extension ReaderControllerPro: DocumentClosable {}
extension ReaderControllerPro: DocumentPrintable {}
extension ReaderControllerPro: DocumentHealthPresentable {}
extension ReaderControllerPro: DocumentUndoable {}
extension ReaderControllerPro: SelectedTextReplaceable {}

extension ReaderControllerPro {
    func exportDocumentHealthReport() {
        guard let summary = documentHealthSummary else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = summary.documentName.replacingOccurrences(of: ".pdf", with: "", options: [.caseInsensitive]) + "-health-report.txt"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try summary.plainTextReport().write(to: url, atomically: true, encoding: .utf8)
                log = "Exported health report to \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                log = "Health report export failed: \(error.localizedDescription)"
                present(error)
            }
        }
    }
}

extension ReaderControllerPro: FileExportable {
    func exportSanitized() {
        guard let doc = document else { return }
        let snapshotDoc: PDFDocument
        do {
            snapshotDoc = try PDFOps.privacyPreservingSnapshot(document: doc)
        } catch {
            log = "Export failed: couldn't read current document state"
            return
        }
        let sendableSnapshot = SendablePDFDocument(document: snapshotDoc)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-sanitized.pdf"

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

            // Persist default if checkbox is on
            if checkbox.state == .on {
                SanitizeDefaults.shared.defaultProfile = profile
            }

            isProcessing = true
            loadingStatus = "Sanitizing..."

            let sourceURL = currentURL
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer {
                    Task { @MainActor [weak self] in
                        self?.isProcessing = false
                        self?.loadingStatus = nil
                    }
                }

                do {
                    let processed = try PDFDocumentSanitizer.sanitize(document: sendableSnapshot.document,
                                                                      sourceURL: sourceURL,
                                                                      options: options)
                    { processed, total in
                        Task { @MainActor [weak self] in
                            self?.loadingStatus = "Sanitizing \(processed)/\(total)"
                        }
                    } shouldCancel: {
                        false
                    }

                    guard processed.write(to: destination) else {
                        // Throwing a generic error since we don't have access to PDFOpsError easily here without importing it or defining it
                        throw NSError(domain: "PDFQuickFix", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to save sanitized document"])
                    }

                    Task { @MainActor [weak self] in
                        self?.log = "Exported sanitized (\(profile.rawValue)) to \(destination.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.log = "Sanitization failed: \(error.localizedDescription)"
                        self?.present(error)
                    }
                }
            }
        }
    }

    func exportOptimized() {
        guard let doc = document else {
            log = "Export failed: no document is loaded"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-optimized.pdf"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshotData: Data
        do {
            let snapshot = try PDFOps.privacyPreservingSnapshot(document: doc)
            guard let data = snapshot.dataRepresentation() else {
                throw PDFOpsError.saveFailed
            }
            snapshotData = data
        } catch {
            log = "Optimize export failed: \(error.localizedDescription)"
            present(error)
            return
        }

        isProcessing = true
        log = "Optimizing \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                guard let snapshot = PDFDocument(data: snapshotData),
                      let optimizedData = PDFOps.optimize(document: snapshot)
                else {
                    throw PDFOpsError.saveFailed
                }
                try optimizedData.write(to: url, options: .atomic)
                Task { @MainActor [weak self] in
                    self?.isProcessing = false
                    self?.log = "Exported optimized copy to \(url.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isProcessing = false
                    self?.log = "Optimize export failed: \(error.localizedDescription)"
                    self?.present(error)
                }
            }
        }
    }

    func exportMetadataCleaned() {
        guard let doc = document else {
            log = "Export failed: no document is loaded"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-metadata-clean.pdf"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let cleanedData = try PDFOps.metadataCleanedData(document: doc, sourceURL: currentURL)
                try cleanedData.write(to: url, options: .atomic)
                log = "Exported metadata-clean copy to \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                log = "Metadata-clean export failed: \(error.localizedDescription)"
                present(error)
            }
        }
    }

    func exportFlattened() {
        guard let doc = document else {
            log = "Export failed: no document is loaded"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (doc.documentURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-flattened.pdf"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let flattenedData = try PDFOps.flattenedData(document: doc)
                try flattenedData.write(to: url, options: .atomic)
                log = "Exported flattened copy to \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                log = "Flattened export failed: \(error.localizedDescription)"
                present(error)
            }
        }
    }

    func exportEncrypted() {
        guard let doc = document else {
            log = "Export failed: no document is loaded"
            return
        }
        guard let options = PDFEncryptionExport.requestOptions() else { return }

        do {
            if let url = try PDFEncryptionExport.writeEncryptedCopy(
                document: doc,
                sourceURL: currentURL ?? doc.documentURL,
                options: options
            ) {
                log = "Exported encrypted copy to \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            log = "Encrypted export failed: \(error.localizedDescription)"
            present(error)
        }
    }
}

/// PDFViewDelegate conformance kept nonisolated to satisfy protocol requirements
/// while updating state on the main actor explicitly.
extension ReaderControllerPro: PDFViewDelegate {
    nonisolated func pdfViewWillChangeScaleFactor(_: PDFView, toScale scale: CGFloat) -> CGFloat {
        Task { @MainActor [weak self] in
            self?.zoomScale = scale
        }
        return scale
    }
}

struct ReaderProView: View, Equatable {
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

    static func == (lhs: ReaderProView, rhs: ReaderProView) -> Bool {
        lhs.controller === rhs.controller &&
            lhs.selectedTab == rhs.selectedTab
    }

    /// Computed profile based on current document
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
            .overlay(alignment: .bottomTrailing) {
                if controller.isRepaired {
                    Text("Normalized")
                        .font(.caption)
                        .padding(6)
                        .background(.thinMaterial)
                        .cornerRadius(8)
                        .padding()
                }
            }
            .focusedSceneValue(\.fileExportable, controller)
            .focusedSceneValue(\.documentPrintable, controller)
            .focusedSceneValue(\.pdfActionable, controller)
            .focusedSceneValue(\.documentClosable, controller)
            .focusedSceneValue(\.documentHealthPresentable, controller)
            .focusedSceneValue(\.documentUndoable, controller)
            .focusedSceneValue(\.selectedTextReplaceable, controller)
            .onDrop(of: [.fileURL, .url, .pdf], delegate: PDFURLDropDelegate { url in
                droppedURL = url
            })
            .onChange(of: droppedURL) { newValue in
                guard let url = newValue, url != lastOpenedURL else { return }
                droppedURL = nil
                lastOpenedURL = url
                controller.open(url: url)
            }
            .sheet(isPresented: $quickFixPresented) {
                QuickFixSheet(inputURL: $lastOpenedURL) { output in
                    if let output {
                        let access = OutputDirectoryAccessStore.shared.access(for: output.deletingLastPathComponent())
                        lastOpenedURL = output
                        controller.open(url: output, access: access)
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
            .sheet(isPresented: $controller.isDocumentHealthPresented) {
                if let summary = controller.documentHealthSummary {
                    DocumentHealthSheet(
                        summary: summary,
                        onRepairAndSaveAs: { controller.repairAndSaveAs() },
                        onExportSanitized: { controller.exportSanitized() },
                        onExportReport: { controller.exportDocumentHealthReport() },
                        onOpenQuickFix: { selectedTab = .quickFix }
                    )
                } else {
                    Text("No active document.")
                        .padding(24)
                }
            }
            .onAppear {
                syncFromHub()
                if documentHub.syncEnabled, documentHub.currentURL == nil {
                    documentHub.update(url: controller.currentURL, from: .reader)
                }
            }
            .onChange(of: controller.currentURL) { url in
                if let url {
                    lastOpenedURL = url
                } else {
                    lastOpenedURL = nil
                }
                guard let url, url != documentHub.currentURL else { return }
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
        let exportDocument: PDFDocument
        do {
            exportDocument = try PDFOps.privacyPreservingDocumentForExport(doc)
        } catch {
            controller.log = "Encrypt failed: \(error.localizedDescription)"
            return
        }
        guard let data = PDFSecurity.encrypt(
            document: exportDocument,
            userPassword: userPassword,
            ownerPassword: ownerPassword.isEmpty ? nil : ownerPassword,
            keyLength: 128
        ) else {
            controller.log = "Encrypt failed: unsupported encryption settings"
            return
        }

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

    /// Grid layout for recent files (2 columns)
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
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
                            .foregroundColor(isDragging ? AppTheme.Colors.accent : AppTheme.Colors.dropZoneStroke)
                            .background(
                                RoundedRectangle(cornerRadius: AppTheme.Metrics.dropZoneCornerRadius, style: .continuous)
                                    .fill(isDragging ? AppTheme.Colors.dropZoneFillHighlighted : AppTheme.Colors.dropZoneFill)
                            )

                        VStack(spacing: 20) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 64))
                                .foregroundColor(AppTheme.Colors.accent)

                            VStack(spacing: 10) {
                                Text("Private Cleanup Desk")
                                    .font(.system(size: 12, weight: .semibold))
                                    .tracking(1.6)
                                    .foregroundColor(AppTheme.Colors.accent)
                                Text("Open a PDF to inspect it privately and prepare a safer outbound copy")
                                    .font(.system(size: 24, weight: .bold))
                                    .foregroundColor(AppTheme.Colors.primaryText)
                                    .multilineTextAlignment(.center)
                                Text("Drag a PDF here or browse from your Mac. Review, cleanup, and export stay on this device.")
                                    .font(.body)
                                    .foregroundColor(AppTheme.Colors.secondaryText)
                                    .multilineTextAlignment(.center)
                                Text("For folder-wide cleanup, use Sanitize Folder to create reviewed outbound copies and capture a handoff receipt.")
                                    .font(.caption)
                                    .foregroundColor(AppTheme.Colors.accent)
                                    .multilineTextAlignment(.center)
                            }
                        }
                    }
                    .frame(height: 320)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onDrop(of: [.fileURL, .url, .pdf], isTargeted: $isDragging) { providers in
                    handlePDFDrop(providers) { url in
                        controller.open(url: url)
                    }
                }

                // Recent Files
                if !recentFiles.recentFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recent Desk")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(AppTheme.Colors.accent)
                                Text("Return to the files you recently inspected")
                                    .font(.title3.weight(.semibold))
                                    .foregroundColor(AppTheme.Colors.primaryText)
                            }
                            Spacer()
                            Text("\(recentFiles.recentFiles.count) saved")
                                .font(.caption)
                                .foregroundColor(AppTheme.Colors.secondaryText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(AppTheme.Colors.cardBackground)
                                .cornerRadius(AppTheme.Metrics.smallCornerRadius)
                        }

                        Text("Recent work stays visible so you can reopen, inspect, and continue cleanup without searching Finder.")
                            .font(.caption)
                            .foregroundColor(AppTheme.Colors.secondaryText)

                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(recentFiles.recentFiles.prefix(6)) { file in
                                Button(action: {
                                    do {
                                        let resolved = try recentFiles.resolveForOpen(file)
                                        controller.open(url: resolved.url, access: resolved.access)
                                    } catch {
                                        let alert = NSAlert()
                                        alert.messageText = "Cannot open file"
                                        alert.informativeText = "The file at '\(file.displayName)' could not be found or opened. It may have been moved or deleted."
                                        alert.addButton(withTitle: "OK")
                                        alert.addButton(withTitle: "Remove from Recents")
                                        if alert.runModal() == .alertSecondButtonReturn {
                                            recentFiles.remove(file)
                                        }
                                    }
                                }) {
                                    HStack(spacing: 16) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: AppTheme.Metrics.thumbnailCornerRadius, style: .continuous)
                                                .fill(AppTheme.Colors.thumbnailBackground)
                                                .frame(width: 52, height: 68)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: AppTheme.Metrics.thumbnailCornerRadius, style: .continuous)
                                                        .stroke(AppTheme.Colors.thumbnailBorder, lineWidth: 0.5)
                                                )
                                                .shadow(color: AppTheme.Shadows.card.opacity(0.57), radius: 2, x: 0, y: 1)

                                            VStack(alignment: .leading, spacing: 4) {
                                                RoundedRectangle(cornerRadius: 1)
                                                    .fill(Color.gray.opacity(0.3))
                                                    .frame(width: 34, height: 3)

                                                RoundedRectangle(cornerRadius: 1)
                                                    .fill(Color.gray.opacity(0.3))
                                                    .frame(width: 24, height: 3)

                                                Spacer()
                                            }
                                            .padding(8)
                                        }

                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(file.displayName)
                                                .font(.headline)
                                                .fontWeight(.medium)
                                                .foregroundColor(AppTheme.Colors.primaryText)
                                                .lineLimit(1)
                                                .truncationMode(.middle)

                                            Text(file.date.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundColor(AppTheme.Colors.secondaryText)

                                            Text("Reopen from the private cleanup desk")
                                                .font(.caption2)
                                                .foregroundColor(AppTheme.Colors.accent)
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
            HStack(spacing: 12) {
                Text("Reader")
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(AppTheme.Colors.primaryText)

                Spacer()

                Button {
                    standaloneQuickFixPresented = true
                } label: {
                    Label("AI Tools", systemImage: "sparkles")
                }
                .buttonStyle(ReaderToolbarButtonStyle())

                Button {
                    controller.replaceSelectedTextWithPrompt()
                } label: {
                    Label("Replace Text", systemImage: "text.cursor")
                }
                .buttonStyle(ReaderToolbarButtonStyle())
                .disabled(controller.currentSelectionText == nil)

                Button {
                    controller.redactSelectedTextWithConfirmation()
                } label: {
                    Label("Redact", systemImage: "rectangle.fill.on.rectangle.fill")
                }
                .buttonStyle(ReaderToolbarButtonStyle())
                .disabled(controller.currentSelectionText == nil)

                Button {
                    quickFixPresented = true
                } label: {
                    Label("QuickFix", systemImage: "wand.and.stars")
                }
                .buttonStyle(ReaderToolbarButtonStyle())
                .disabled(controller.currentURL == nil)

                Button {
                    showEncrypt = true
                } label: {
                    Label("Encrypt", systemImage: "lock")
                }
                .buttonStyle(ReaderToolbarButtonStyle())
                .disabled(controller.document == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppTheme.Colors.cardBackground)
            .overlay(
                Rectangle()
                    .fill(AppTheme.Colors.cardBorder)
                    .frame(height: 1),
                alignment: .bottom
            )

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

private struct ReaderToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundColor(AppTheme.Colors.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? AppTheme.Colors.cardBorder : AppTheme.Colors.sidebarBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.9 : 1.0)
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
                    Text("Open a document to review pages")
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
                    if controller.isMassiveDocument, !controller.hasLoadedOutline {
                        VStack(spacing: 8) {
                            Spacer()
                            Text("Outline loading deferred for performance")
                                .foregroundColor(AppTheme.Colors.secondaryText)
                            Button("Load Outline") {
                                controller.loadOutlineIfNeeded()
                            }
                            .controlSize(.small)
                            Spacer()
                        }
                        .padding()
                    } else if controller.hasLoadedOutline, !controller.outlineRows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            if controller.isOutlineTruncated {
                                Label("Showing the first \(PDFOutlineLoader.massiveDocumentRowLimit) outline items", systemImage: "list.bullet.rectangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                            }
                            OutlineTreeView(rows: controller.outlineRows, pdfView: controller.pdfView)
                        }
                    } else {
                        VStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Text(controller.hasLoadedOutline ? "No outline on this file" : "Outline loading deferred")
                                    .foregroundColor(AppTheme.Colors.secondaryText)
                                Text(controller.hasLoadedOutline ? "Chapter navigation will appear here when the PDF includes bookmarks." : "Chapter navigation loads when this tab is opened.")
                                    .font(.caption)
                                    .foregroundColor(AppTheme.Colors.secondaryText)
                                    .multilineTextAlignment(.center)
                            }
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
        .onChange(of: selection) { newValue in
            loadOutlineWhenVisible(selection: newValue)
        }
        .onChange(of: controller.outlineResetToken) { _ in
            loadOutlineWhenVisible(selection: selection)
        }
    }

    private func loadOutlineWhenVisible(selection: Int) {
        if selection == 1, !controller.isMassiveDocument {
            controller.loadOutlineIfNeeded()
        }
    }
}

// MARK: - Reader Sidebar Right (Comments / Info)

struct ReaderSidebarRight: View {
    @ObservedObject var controller: ReaderControllerPro
    let profile: DocumentProfile

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $controller.selectedRightPanelTab) {
                ForEach(ReaderRightPanelTab.allCases) { tab in
                    Label(tab.displayName, systemImage: tab.symbolName)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            switch controller.selectedRightPanelTab {
            case .info:
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
            case .comments:
                ReaderCommentsPanel(controller: controller)
            case .copilot:
                ReaderCopilotView(controller: controller)
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

struct ReaderCommentsPanel: View {
    @ObservedObject var controller: ReaderControllerPro
    @State private var filterText = ""

    private var filteredAnnotations: [AnnotationRow] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return controller.annotationRows }
        return controller.annotationRows.filter { row in
            row.title.lowercased().contains(query)
                || (row.annotation.contents?.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if controller.isMassiveDocument, controller.annotationRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Annotation evidence loads on demand for very large PDFs.")
                        .font(.caption)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                    Button("Load annotations") {
                        controller.loadAnnotationsForReader(force: true)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(controller.document == nil)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }

            TextField("Filter comments", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.top, 12)

            if filteredAnnotations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.annotationRows.isEmpty ? "No annotations on this file" : "No annotations match this filter")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.Colors.primaryText)
                    Text(controller.annotationRows.isEmpty
                        ? "Comments, highlights, links, and notes on the open PDF will appear here."
                        : "Try a broader search to review the notes already captured in this document.")
                        .font(.caption)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)
            } else {
                List {
                    ForEach(filteredAnnotations) { row in
                        ReaderCommentRow(
                            row: row,
                            focus: controller.focus,
                            edit: controller.editAnnotation(_:draft:),
                            delete: controller.delete
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear {
            controller.loadAnnotationsForReader()
        }
    }
}

private struct ReaderCommentRow: View {
    let row: AnnotationRow
    let focus: (AnnotationRow) -> Void
    let edit: (AnnotationRow, AnnotationEditDraft) -> Void
    let delete: (AnnotationRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.Colors.primaryText)
                Spacer()
                Text("Page \(row.pageIndex + 1)")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }

            if let contents = row.annotation.contents, !contents.isEmpty {
                Text(contents)
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Button {
                    focus(row)
                } label: {
                    Label("Go", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderless)

                Button {
                    if let draft = promptForAnnotationEdit(row) {
                        edit(row, draft)
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    delete(row)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func promptForAnnotationEdit(_ row: AnnotationRow) -> AnnotationEditDraft? {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading

        let field = NSTextField(string: row.annotation.contents ?? "")
        field.placeholderString = "Annotation text"
        field.frame = CGRect(x: 0, y: 0, width: 340, height: 24)
        stack.addArrangedSubview(field)

        var urlField: NSTextField?
        if row.annotation.url != nil || row.annotation.type == PDFAnnotationSubtype.link.rawValue {
            let field = NSTextField(string: row.annotation.url?.absoluteString ?? "")
            field.placeholderString = "https://example.com"
            field.frame = CGRect(x: 0, y: 0, width: 340, height: 24)
            urlField = field
            stack.addArrangedSubview(field)
        }

        let alert = NSAlert()
        alert.messageText = "Edit Annotation"
        alert.informativeText = "Update the note, markup text, or link target for this annotation."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return AnnotationEditDraft(contents: field.stringValue, urlString: urlField?.stringValue)
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
            if controller.document != nil {
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

                    // Performance mode banner for massive documents
                    if controller.isMassiveDocument {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.yellow)
                            Text("Performance Mode • \(controller.document?.pageCount ?? 0) pages")
                                .font(.caption.weight(.medium))
                            Spacer()
                            if let url = controller.currentURL {
                                Button("Open in Preview") {
                                    NSWorkspace.shared.open(url)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(8)
                    }
                }
            } else {
                Text("Open a PDF from the cleanup desk")
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }

            if controller.isLoadingDocument {
                LoadingOverlayView(status: controller.loadingStatus ?? "Loading...")
            }
        }
        .onDrop(of: [.fileURL, .url, .pdf], isTargeted: nil) { providers in
            handlePDFDrop(providers) { url in
                controller.open(url: url)
            }
        }
    }
}

// MARK: - PDFView bridge

struct PDFViewProRepresented: NSViewRepresentable {
    var document: PDFDocument?
    var controller: ReaderControllerPro
    var didCreate: (PDFView) -> Void

    func makeNSView(context _: Context) -> PDFView {
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

    func updateNSView(_ nsView: PDFView, context _: Context) {
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

    override func setCurrentSelection(_ selection: PDFSelection?, animate: Bool) {
        super.setCurrentSelection(selection, animate: animate)
        controller?.handlePDFSelectionChange()
    }

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

    @objc private func rotateLeft(_: Any?) {
        controller?.rotateCurrentPageLeft()
    }

    @objc private func rotateRight(_: Any?) {
        controller?.rotateCurrentPageRight()
    }
}

// MARK: - Thumbnails bridge

struct ThumbnailProRepresentedView: NSViewRepresentable {
    var pdfViewGetter: () -> PDFView?

    func makeNSView(context _: Context) -> PDFThumbnailView {
        let thumbnails = PDFThumbnailView()
        thumbnails.backgroundColor = .clear
        thumbnails.thumbnailSize = NSSize(width: 120, height: 160)
        thumbnails.maximumNumberOfColumns = 1
        thumbnails.pdfView = pdfViewGetter()
        return thumbnails
    }

    func updateNSView(_ nsView: PDFThumbnailView, context _: Context) {
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
