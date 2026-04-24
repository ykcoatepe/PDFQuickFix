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
    @State private var isSavingQuickFixResult: Bool = false
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
            cleanupTransientOutputs()
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
                    let outputURL = quickFixResult.displayOutputURL
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Output packet", detail: "Inspect the generated file and review attached evidence before handoff.")

                        VStack(alignment: .leading, spacing: 10) {
                            evidenceRow("Output", value: outputURL.lastPathComponent)
                            evidenceRow("Folder", value: outputURL.deletingLastPathComponent().path)
                            evidenceRow("Reports", value: availableReportsSummary(for: quickFixResult))
                            if quickFixResult.isTemporaryOutput {
                                evidenceRow("State", value: "Temporary until saved")
                            }
                        }
                        .paperPanelStyle()

                        HStack {
                            Button("Open Result") {
                                openQuickFixResult()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(isSavingQuickFixResult)

                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(isSavingQuickFixResult)

                            if quickFixResult.isTemporaryOutput {
                                Button(isSavingQuickFixResult ? "Saving..." : "Save Result...") {
                                    saveQuickFixResult()
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(isSavingQuickFixResult)
                            }

                            Spacer()

                            Label(quickFixResult.isTemporaryOutput ? "Save before handoff" : "Ready to review", systemImage: "checkmark.circle.fill")
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
        cleanupTransientOutputs()
        quickFixResult = nil
        isProcessing = true
        log = "Processing \(inputURL.lastPathComponent)…\n"

        let model = optionsModel
        let preprocessImages = optionsModel.preprocessImages
        let targetDPI = CGFloat(optionsModel.dpi)
        Task.detached(priority: .userInitiated) {
            let temporaryOutputURL = Self.temporaryFileURL(prefix: "quickfix-output-", extension: "pdf")
            do {
                let prepared = try Self.prepareQuickFixInput(
                    for: inputURL,
                    preprocessImages: preprocessImages,
                    targetDPI: targetDPI
                )
                defer {
                    if let cleanupURL = prepared.cleanupURL {
                        try? FileManager.default.removeItem(at: cleanupURL)
                    }
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
                let result = try model.runQuickFixResult(
                    inputURL: prepared.sourceURL,
                    outputURL: temporaryOutputURL,
                    isTemporaryOutput: true,
                    shouldCancel: { Task.isCancelled },
                    progress: { current, total in
                        DispatchQueue.main.async {
                            self.log += "Progress: \(current)/\(total)\n"
                        }
                    }
                )
                await MainActor.run {
                    self.quickFixResult = result
                    QuickFixResultStore.shared.set(result, sourceURL: inputURL)
                    self.printCoordinator.outputURL = result.displayOutputURL
                    self.log += "✅ Done → temporary result at \(result.outputURL.path)\n"
                    self.isProcessing = false
                }
            } catch {
                try? FileManager.default.removeItem(at: temporaryOutputURL)
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
                    try DocumentTextSession(documentURL: sourceURL).extractText(pageSelection: selection)
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

    private func copyAIOutput() {
        guard !aiOutput.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(aiOutput, forType: .string)
        aiError = nil
        aiStatus = "Copied AI output to clipboard."
    }

    private func saveAIOutput() {
        guard !aiOutput.isEmpty else { return }
        let format = Self.inferAIOutputFormat(from: aiOutput)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .json ? .json : .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.aiOutputFileName(task: aiTask, format: format)
        panel.directoryURL = inputURL?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try Self.writeAIOutput(aiOutput, to: url, format: format)
                aiError = nil
                aiStatus = "Saved AI output to \(url.lastPathComponent)."
            } catch {
                aiError = error.localizedDescription
            }
        }
    }

    private static func aiOutputFileName(task: LocalAITask, format: AIOutputFormat) -> String {
        "\(task.rawValue)-output.\(format.fileExtension)"
    }

    private static func inferAIOutputFormat(from text: String) -> AIOutputFormat {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object) else {
            return .txt
        }
        return .json
    }

    private static func writeAIOutput(_ text: String, to url: URL, format: AIOutputFormat) throws {
        switch format {
        case .txt:
            guard let data = text.data(using: .utf8) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: [.atomic])
        case .json:
            guard let data = text.data(using: .utf8) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let object = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try pretty.write(to: url, options: [.atomic])
        }
    }

    private func saveQuickFixResult() {
        guard let result = quickFixResult else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let suggestedName = Self.quickFixSuggestedFileName(inputURL: inputURL)
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = inputURL?.deletingLastPathComponent() ?? result.outputURL.deletingLastPathComponent()

        isSavingQuickFixResult = true
        defer { isSavingQuickFixResult = false }

        if panel.runModal() == .OK, let destination = panel.url {
            do {
                if destination.standardizedFileURL == result.outputURL.standardizedFileURL {
                    log += "ℹ️ Result already points to \(destination.path)\n"
                    return
                }
                try Self.copyResultPreservingExistingFile(
                    from: result.outputURL,
                    to: destination
                )
                OutputDirectoryAccessStore.shared.store(directory: destination.deletingLastPathComponent())
                let savedResult = result.savedCopy(outputURL: destination)
                let previousOutputURL = result.outputURL
                quickFixResult = savedResult
                QuickFixResultStore.shared.set(savedResult, previousOutputURL: previousOutputURL, sourceURL: inputURL)
                printCoordinator.outputURL = savedResult.displayOutputURL
                log += "💾 Saved result → \(destination.path)\n"
                if result.isTemporaryOutput {
                    try? FileManager.default.removeItem(at: previousOutputURL)
                }
            } catch {
                log += "❌ Save failed: \(error.localizedDescription)\n"
            }
        }
    }

    private func openQuickFixInput() {
        guard let inputURL else { return }
        NSWorkspace.shared.open(inputURL)
    }

    private func openQuickFixResult() {
        guard let quickFixResult else { return }
        NSWorkspace.shared.open(quickFixResult.displayOutputURL)
    }

    private static func quickFixSuggestedFileName(inputURL: URL?) -> String {
        let base = inputURL?.deletingPathExtension().lastPathComponent ?? "QuickFix"
        return "\(base)-fixed.pdf"
    }

    private func cleanupTransientOutputs() {
        if let cached = aiImageOCRURL {
            try? FileManager.default.removeItem(at: cached)
            aiImageOCRURL = nil
        }
        if let result = quickFixResult, result.isTemporaryOutput {
            try? FileManager.default.removeItem(at: result.outputURL)
        }
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
            if let cached = Self.existingCachedOCRURL(aiImageOCRURL) {
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

    static func existingCachedOCRURL(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func generateImageOCRTextSource(from imageURL: URL) async throws -> URL {
        let parameters = await MainActor.run { optionsModel.makeAIImageOCRParameters() }
        let preprocessImages = await MainActor.run { optionsModel.preprocessImages }
        let targetDPI = await MainActor.run { CGFloat(optionsModel.dpi) }
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

    static func copyResultPreservingExistingFile(from sourceURL: URL,
                                                 to destinationURL: URL,
                                                 fileManager: FileManager = .default) throws {
        let tempCopyURL = temporaryFileURL(prefix: "quickfix-save-", extension: destinationURL.pathExtension.isEmpty ? "pdf" : destinationURL.pathExtension)
        do {
            try fileManager.copyItem(at: sourceURL, to: tempCopyURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempCopyURL)
            } else {
                try fileManager.moveItem(at: tempCopyURL, to: destinationURL)
            }
        } catch {
            if fileManager.fileExists(atPath: tempCopyURL.path) {
                try? fileManager.removeItem(at: tempCopyURL)
            }
            throw error
        }
    }

    private nonisolated static func temporaryFileURL(prefix: String, extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

}

private enum AIOutputFormat {
    case txt
    case json

    var fileExtension: String {
        switch self {
        case .txt:
            return "txt"
        case .json:
            return "json"
        }
    }
}

private struct QuickFixPreviewCard: View {
    let inputURL: URL?
    let result: QuickFixResult
    let isSaving: Bool
    let onOpenBefore: () -> Void
    let onOpenAfter: () -> Void
    let onSaveResult: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTheme.Colors.support)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("QuickFix Result")
                        .appFont(.headline)
                    Text(result.isTemporaryOutput ? "Temporary output ready for review." : "Saved output selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let pageIndex = result.previewPageIndex {
                    Text("Preview page \(pageIndex + 1)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                previewColumn(
                    title: "Before",
                    fileName: inputURL?.lastPathComponent ?? "No source selected",
                    systemImage: "doc",
                    actionTitle: "Open Before",
                    action: onOpenBefore,
                    enabled: inputURL != nil
                )

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                previewColumn(
                    title: "After",
                    fileName: result.displayOutputURL.lastPathComponent,
                    systemImage: "doc.text.fill",
                    actionTitle: isSaving ? "Saving…" : "Open After",
                    action: onOpenAfter,
                    enabled: !isSaving
                )
            }

            HStack {
                if result.isTemporaryOutput {
                    Text("The output is temporary until you save it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The output has been saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(isSaving ? "Saving…" : "Save Result…") {
                    onSaveResult()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isSaving)
            }
        }
        .padding()
        .background(AppTheme.Colors.support.opacity(0.08))
        .cornerRadius(AppTheme.Metrics.cardCornerRadius)
    }

    @ViewBuilder
    private func previewColumn(title: String,
                               fileName: String,
                               systemImage: String,
                               actionTitle: String,
                               action: @escaping () -> Void,
                               enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button(actionTitle) {
                action()
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Metrics.smallCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius)
                .stroke(AppTheme.Colors.cardBorder, lineWidth: 0.5)
        )
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
