import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

struct QuickFixTab: View {
    @EnvironmentObject private var aiSettings: LocalAISettings
    @EnvironmentObject private var aiInteractions: AIInteractionStore
    @Environment(\.openWindow) private var openWindow

    private let autoTag = "__default__"

    @State private var inputURL: URL?
    @State private var quickFixResult: QuickFixResult?
    @StateObject private var optionsModel = QuickFixOptionsModel()
    @State private var isProcessing: Bool = false
    @State private var log: String = ""
    @State private var aiTask: LocalAITask = .summarize
    @State private var aiOutput: String = ""
    @State private var aiStatus: String = ""
    @State private var aiError: String?
    @State private var isAIRunning: Bool = false
    @State private var aiTargetLanguage: String = "English"
    @State private var aiFieldList: String = ""
    @State private var aiPageSelection: String = ""
    @State private var aiImageOCRURL: URL?
    @StateObject private var printCoordinator = QuickFixPrintCoordinator()

    var body: some View {
        VSplitView {
            quickFixPane
                .frame(minHeight: 320)
            aiToolsPane
                .frame(minHeight: 240)
        }
        .background(AppTheme.Colors.background)
        .onChange(of: inputURL) { _ in
            if let cached = aiImageOCRURL {
                try? FileManager.default.removeItem(at: cached)
            }
            quickFixResult = nil
            aiOutput = ""
            aiStatus = ""
            aiError = nil
            aiImageOCRURL = nil
            printCoordinator.inputURL = inputURL
            printCoordinator.outputURL = nil
        }
        .onChange(of: quickFixResult?.outputURL) { outputURL in
            printCoordinator.outputURL = outputURL
        }
        .onAppear {
            printCoordinator.inputURL = inputURL
            printCoordinator.outputURL = quickFixResult?.outputURL
        }
        .task {
            await aiSettings.refreshModelsIfNeeded()
        }
        .focusedSceneValue(\.documentPrintable, printCoordinator.hasPrintableDocument ? printCoordinator : nil)
    }

    private var quickFixPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cleanup Workbench")
                        .appFont(.largeTitle, weight: .bold)
                    Text("Repair, redact, replace, OCR, and local AI workflows for outbound PDFs that stay on your Mac.")
                        .appFont(.body)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }

                BatchSanitizeWorkbenchCallout(
                    eyebrow: "Folder lane",
                    title: "Use Sanitize Folder… when the outbound job is larger than one file",
                    detail: "Batch runs write reviewed outbound copies to a separate folder and end with a processed/skipped/failed receipt."
                )

                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Button(action: pickInput) {
                            Label("Choose PDF or Image…", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        if let inputURL {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(AppTheme.Colors.accent)
                                Text(inputURL.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(AppTheme.Colors.cardBackground)
                            .cornerRadius(AppTheme.Metrics.smallCornerRadius)
                        } else {
                            Text("Choose one file to start a private cleanup pass")
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                                .padding(.horizontal, 8)
                        }

                        Spacer()

                        Button(action: runProcess) {
                            if isProcessing {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Process", systemImage: "gearshape.2.fill")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle(isDisabled: inputURL == nil || isProcessing))
                        .disabled(inputURL == nil || isProcessing)
                    }

                    DropAreaView(inputURL: $inputURL)
                        .frame(maxWidth: .infinity, minHeight: 140)
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 12) {
                    Label("Options", systemImage: "slider.horizontal.3")
                        .appFont(.headline)
                        .foregroundStyle(AppTheme.Colors.primaryText)
                    Text("Control OCR, redaction, search-replace, and image cleanup before generating the reviewed outbound copy.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                    QuickFixOptionsForm(model: optionsModel)
                }
                .cardStyle()

                if !log.isEmpty {
                    ScrollView {
                        Text(log)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .frame(height: 120)
                    .background(AppTheme.Colors.cardBackground)
                    .cornerRadius(AppTheme.Metrics.smallCornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius)
                            .stroke(AppTheme.Colors.cardBorder, lineWidth: 0.5)
                    )
                }

                if let quickFixResult {
                    let outputURL = quickFixResult.outputURL
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Output packet", detail: "Inspect the generated file and review attached evidence before handoff.")

                        VStack(alignment: .leading, spacing: 10) {
                            evidenceRow("Output", value: outputURL.lastPathComponent)
                            evidenceRow("Folder", value: outputURL.deletingLastPathComponent().path)
                            evidenceRow("Reports", value: availableReportsSummary(for: quickFixResult))
                        }
                        .paperPanelStyle()

                        HStack {
                            Button("Open Result") {
                                NSWorkspace.shared.open(outputURL)
                            }
                            .buttonStyle(SecondaryButtonStyle())

                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                            }
                            .buttonStyle(SecondaryButtonStyle())

                            Spacer()

                            Label("Ready to review", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.support)
                        }
                    }
                    .cardStyle()
                }

                if let report = quickFixResult?.redactionReport {
                    RedactionReportView(report: report)
                }

                if let report = quickFixResult?.ocrReport {
                    OCRReportView(report: report)
                }
            }
            .padding(24)
        }
    }

    private var aiToolsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Local AI Tools", systemImage: "bolt.circle")
                            .appFont(.headline)
                            .foregroundStyle(AppTheme.Colors.primaryText)
                        Text("Run local summary, extraction, OCR, and translation tasks, then inspect the evidence log.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    }
                    Spacer()
                    Button("AI Activity") {
                        openWindow(id: "ai-activity")
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                Picker("Task", selection: $aiTask) {
                    ForEach(LocalAITask.allCases) { task in
                        Text(task.displayName).tag(task)
                    }
                }
                .pickerStyle(.segmented)

                if aiSettings.availableModels.isEmpty {
                    Text("No local model available. Refresh in Settings.")
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                        .font(.caption)
                } else {
                    Picker("Model", selection: overrideBinding(for: aiTask)) {
                        Text(defaultModelLabel).tag(autoTag)
                        ForEach(aiSettings.availableModels) { model in
                            Text(aiSettings.displayName(for: model.name)).tag(model.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320, alignment: .leading)
                }

                if aiTask.requiresTargetLanguage {
                    HStack {
                        Text("Target language")
                        TextField("English", text: $aiTargetLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("Target language")
                    }
                }

                if aiTask == .summarize {
                    HStack {
                        Text("Pages")
                        TextField("All (e.g. 1-3, 6)", text: $aiPageSelection)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("Pages")
                    }
                }

                if aiTask.requiresFieldList {
                    HStack {
                        Text("Fields (comma-separated)")
                        TextField("invoice_number,total,invoice_date", text: $aiFieldList)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Fields")
                    }
                }

                HStack(spacing: 12) {
                    Button(isAIRunning ? "Running…" : "Run \(aiTask.displayName)") {
                        runAITask()
                    }
                    .buttonStyle(PrimaryButtonStyle(isDisabled: !canRunAITask))
                    .disabled(!canRunAITask)

                    if let modelName = aiSettings.modelFor(task: aiTask) {
                        Text("Model: \(aiSettings.displayName(for: modelName))")
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                            .font(.caption)
                    } else {
                        Text("No local model available. Refresh in Settings.")
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                            .font(.caption)
                    }
                }

                if !aiStatus.isEmpty {
                    Text(aiStatus)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }

                if let aiError {
                    Text(aiError)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.error)
                }

                if !aiOutput.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("AI Output")
                            .appFont(.headline)
                            .foregroundStyle(AppTheme.Colors.paperText)
                        ScrollView {
                            Text(aiOutput)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 160, maxHeight: 280)
                    }
                    .paperPanelStyle()
                }
            }
            .cardStyle()
            .padding(24)
        }
    }

    private func pickInput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        if panel.runModal() == .OK {
            inputURL = panel.url
            quickFixResult = nil
        }
    }

    private func runProcess() {
        guard !isProcessing, let inputURL else { return }
        isProcessing = true
        log = "Processing \(inputURL.lastPathComponent)…\n"

        let model = optionsModel
        let preprocessImages = optionsModel.preprocessImages
        let targetDPI = CGFloat(optionsModel.dpi)
        Task.detached(priority: .userInitiated) {
            do {
                let prepared = try Self.prepareQuickFixInput(
                    for: inputURL,
                    preprocessImages: preprocessImages,
                    targetDPI: targetDPI
                )
                let defaultOutput = prepared.outputURL ?? inputURL.deletingPathExtension().appendingPathExtension("fixed.pdf")
                let outputSelection = try await MainActor.run {
                    try resolveQuickFixOutputSelection(
                        defaultOutputURL: defaultOutput,
                        preferredOutputURL: prepared.outputURL
                    )
                }
                if prepared.wasConverted {
                    await MainActor.run {
                        if prepared.didPreprocess {
                            self.log += "✨ Auto-cropped & deskewed image.\n"
                        }
                        self.log += "📄 Converted image to PDF for OCR…\n"
                    }
                }
                if let document = PDFDocument(url: prepared.sourceURL) {
                    await MainActor.run {
                        self.log += "📄 Pages: \(document.pageCount)\n"
                    }
                }
                let result = try withExtendedLifetime(outputSelection.access) {
                    try model.runQuickFixResult(
                        inputURL: prepared.sourceURL,
                        outputURL: outputSelection.url,
                        shouldCancel: { Task.isCancelled },
                        progress: { current, total in
                            DispatchQueue.main.async {
                                self.log += "Progress: \(current)/\(total)\n"
                            }
                        }
                    )
                }
                if let cleanupURL = prepared.cleanupURL {
                    try? FileManager.default.removeItem(at: cleanupURL)
                }
                await MainActor.run {
                    self.quickFixResult = result
                    QuickFixResultStore.shared.set(result)
                    self.log += "✅ Done → \(result.outputURL.path)\n"
                    self.isProcessing = false
                }
            } catch QuickFixOutputSelectionError.cancelled {
                await MainActor.run {
                    self.log += "⚠️ Cancelled: output location not selected.\n"
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.log += "❌ Error: \(error.localizedDescription)\n"
                    self.isProcessing = false
                }
            }
        }
    }

    private var canRunAITask: Bool {
        guard !isAIRunning else { return false }
        guard aiSettings.modelFor(task: aiTask) != nil else { return false }
        return inputURL != nil || quickFixResult != nil
    }

    private var defaultModelLabel: String {
        if aiSettings.defaultModel.isEmpty {
            return "Use Default"
        }
        return "Use Default (\(aiSettings.displayName(for: aiSettings.defaultModel)))"
    }

    private func runAITask() {
        guard canRunAITask else { return }
        aiError = nil
        aiOutput = ""
        aiStatus = "Preparing document text…"
        isAIRunning = true

        let sourceName = inputURL?.lastPathComponent
        let task = aiTask
        let modelName = aiSettings.modelFor(task: task)
        let parameters = LocalAITaskParameters(
            targetLanguage: aiTargetLanguage,
            extractionFields: aiFieldList.split(separator: ",").map { String($0) }
        )
        Task {
            do {
                let sourceURL = try await resolveAITaskSourceURL()
                let selection = task == .summarize ? aiPageSelection : ""
                let text = try await Task.detached(priority: .userInitiated) {
                    try PDFTextExtractor.extractText(from: sourceURL, pageSelection: selection)
                }.value
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updateAIState(error: "No text found. Run OCR first, then try again.")
                    return
                }
                aiStatus = "Running \(task.displayName)…"
                let runner = LocalAITaskRunner(
                    interactionStore: aiInteractions,
                    client: OllamaClient(requestTimeout: TimeInterval(aiSettings.requestTimeoutSeconds))
                )
                let result = try await runner.run(
                    task: task,
                    text: text,
                    parameters: parameters,
                    sourceName: sourceName,
                    modelName: modelName
                )
                aiOutput = result.output
                if result.inputWasTrimmed {
                    aiStatus = "Used \(result.inputCharacterCount) chars (trimmed). Model: \(result.model)."
                } else {
                    aiStatus = "Model: \(result.model)."
                }
                isAIRunning = false
            } catch {
                updateAIState(error: aiErrorMessage(from: error))
            }
        }
    }

    @MainActor
    private func updateAIState(error: String) {
        aiError = error
        aiStatus = ""
        isAIRunning = false
    }

    private func aiErrorMessage(from error: Error) -> String {
        if let extractorError = error as? PDFTextExtractorError {
            return extractorError.localizedDescription
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "Request timed out. Try a smaller document or a faster model, then retry."
        }
        return error.localizedDescription
    }

    private func overrideBinding(for task: LocalAITask) -> Binding<String> {
        Binding<String>(
            get: {
                aiSettings.override(for: task) ?? autoTag
            },
            set: { newValue in
                let value = newValue == autoTag ? nil : newValue
                aiSettings.setOverride(task: task, model: value)
            }
        )
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(.headline)
                .foregroundStyle(AppTheme.Colors.primaryText)
            Text(detail)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText)
        }
    }

    private func evidenceRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.paperText.opacity(0.72))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.paperText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func availableReportsSummary(for result: QuickFixResult) -> String {
        let reports = ["Redaction", "OCR"]
        return reports.joined(separator: ", ")
    }

    private nonisolated static func prepareQuickFixInput(for url: URL,
                                                        preprocessImages: Bool,
                                                        targetDPI: CGFloat) throws -> (sourceURL: URL, outputURL: URL?, cleanupURL: URL?, wasConverted: Bool, didPreprocess: Bool) {
        guard let kind = documentInputKind(for: url) else {
            return (url, nil, nil, false, false)
        }
        switch kind {
        case .pdf:
            return (url, nil, nil, false, false)
        case .image:
            let conversion = try ImagePDFConverter.convertImageToPDF(
                at: url,
                preprocess: preprocessImages,
                targetDPI: targetDPI
            )
            let pdfURL = conversion.url
            let outputURL = url.deletingPathExtension().appendingPathExtension("fixed.pdf")
            return (pdfURL, outputURL, pdfURL, true, conversion.didPreprocess)
        }
    }

    private func resolveAITaskSourceURL() async throws -> URL {
        if let quickFixResult {
            return quickFixResult.outputURL
        }
        guard let inputURL else {
            throw PDFTextExtractorError.missingInput
        }
        if documentInputKind(for: inputURL) == .image {
            if let cached = aiImageOCRURL {
                return cached
            }
            await MainActor.run {
                aiStatus = "Running OCR for image…"
            }
            let generated = try await generateImageOCRTextSource(from: inputURL)
            await MainActor.run {
                aiImageOCRURL = generated
            }
            return generated
        }
        return inputURL
    }

    private func generateImageOCRTextSource(from imageURL: URL) async throws -> URL {
        let (parameters, preprocessImages, targetDPI) = await MainActor.run {
            (optionsModel.makeParameters(), optionsModel.preprocessImages, CGFloat(optionsModel.dpi))
        }
        return try await Task.detached(priority: .userInitiated) {
            let conversion = try ImagePDFConverter.convertImageToPDF(
                at: imageURL,
                preprocess: preprocessImages,
                targetDPI: targetDPI
            )
            let tempInput = conversion.url
            let outputURL = Self.temporaryFileURL(prefix: "ai-ocr-", extension: "pdf")
            var options = parameters.options
            options.doOCR = true
            let engine = PDFQuickFixEngine(options: options, languages: parameters.languages)
            _ = try engine.processResult(
                inputURL: tempInput,
                outputURL: outputURL,
                redactionPatterns: [],
                customRegexes: [],
                findReplace: [],
                manualRedactions: [:],
                shouldCancel: { Task.isCancelled }
            )
            try? FileManager.default.removeItem(at: tempInput)
            return outputURL
        }.value
    }

    private nonisolated static func temporaryFileURL(prefix: String, extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

}

@MainActor
final class QuickFixPrintCoordinator: ObservableObject, DocumentPrintable {
    @Published var inputURL: URL?
    @Published var outputURL: URL?

    var hasPrintableDocument: Bool {
        printableURL != nil
    }

    func printDocument() {
        guard let url = printableURL else {
            DocumentPrintService.presentUnavailableAlert(message: "No printable PDF is available in QuickFix.")
            return
        }
        guard let document = PDFDocument(url: url) else {
            DocumentPrintService.presentUnavailableAlert(message: "Couldn't prepare this PDF for printing.")
            return
        }
        _ = DocumentPrintService.print(document: document,
                                       jobTitle: url.lastPathComponent,
                                       source: "quickfix",
                                       showUnavailableAlert: true)
    }

    private var printableURL: URL? {
        if let outputURL, isPDF(outputURL) {
            return outputURL
        }
        if let inputURL, isPDF(inputURL) {
            return inputURL
        }
        return nil
    }

    private func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }
}

enum PDFTextExtractor {
    static func extractText(from url: URL, pageSelection: String? = nil) throws -> String {
        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data) else {
            return ""
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { return "" }
        let pages = try parsePageSelection(pageSelection, pageCount: pageCount)
        var combined = ""
        for index in pages {
            guard let page = document.page(at: index), let text = page.string else { continue }
            combined.append("--- Page \(index + 1) ---\n")
            combined.append(text)
            combined.append("\n\n")
        }
        return combined
    }

    private static func parsePageSelection(_ selection: String?, pageCount: Int) throws -> [Int] {
        guard let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selection.isEmpty else {
            return Array(0..<pageCount)
        }
        var selected = Set<Int>()
        for token in selection.split(separator: ",") {
            let trimmed = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 1 {
                let value = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let page = Int(value) else {
                    throw PDFTextExtractorError.invalidPageSelection(String(trimmed))
                }
                try validatePage(page, pageCount: pageCount)
                selected.insert(page - 1)
            } else if parts.count == 2 {
                let startString = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let endString = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let start = Int(startString), let end = Int(endString), start <= end else {
                    throw PDFTextExtractorError.invalidPageSelection(String(trimmed))
                }
                try validatePage(start, pageCount: pageCount)
                try validatePage(end, pageCount: pageCount)
                for page in start...end {
                    selected.insert(page - 1)
                }
            } else {
                throw PDFTextExtractorError.invalidPageSelection(String(trimmed))
            }
        }

        let sorted = selected.sorted()
        if sorted.isEmpty {
            throw PDFTextExtractorError.emptyPageSelection
        }
        return sorted
    }

    private static func validatePage(_ page: Int, pageCount: Int) throws {
        guard page >= 1 && page <= pageCount else {
            throw PDFTextExtractorError.pageOutOfRange(page, pageCount)
        }
    }
}

enum PDFTextExtractorError: LocalizedError {
    case invalidPageSelection(String)
    case pageOutOfRange(Int, Int)
    case emptyPageSelection
    case missingInput

    var errorDescription: String? {
        switch self {
        case .invalidPageSelection(let token):
            return "Invalid page selection: \"\(token)\". Use formats like 1-3, 6."
        case .pageOutOfRange(let page, let total):
            return "Page \(page) is out of range. This PDF has \(total) pages."
        case .emptyPageSelection:
            return "No pages selected. Enter a page range like 1-3."
        case .missingInput:
            return "Select a PDF or image first."
        }
    }
}

struct DropAreaView: View {
    @Binding var inputURL: URL?
    @State private var isDragging = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isDragging ? AppTheme.Colors.accent : AppTheme.Colors.cardBorder)
                .background(isDragging ? AppTheme.Colors.accent.opacity(0.05) : Color.clear)

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 32))
                    .foregroundStyle(isDragging ? AppTheme.Colors.accent : AppTheme.Colors.secondaryText)

                VStack(spacing: 4) {
                    Text("Drop one PDF or image here")
                        .appFont(.headline)
                    Text("or click “Choose PDF or Image…” above to start the desk")
                        .appFont(.subheadline)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
            }
        }
        .onDrop(of: [.fileURL, .pdf, .png, .jpeg], isTargeted: $isDragging) { providers in
            handleDocumentDrop(providers, allowedTypes: [.pdf, .png, .jpeg]) { url in
                inputURL = url
            }
        }
        .animation(.easeInOut, value: isDragging)
    }
}
