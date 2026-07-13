import AppKit
import PDFQuickFixKit
import SwiftUI

/// Coordinator for batch sanitization operations.
/// Uses NSWindow-based panel since this is a standalone operation not tied to a document.
@MainActor
final class BatchSanitizeCoordinator: ObservableObject {
    static let shared = BatchSanitizeCoordinator()

    private var windowController: BatchSanitizeWindowController?

    private init() {}

    func showBatchSanitizePanel() {
        if let existing = windowController {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = BatchSanitizeWindowController()
        controller.showWindow(nil)
        windowController = controller

        // Clear reference when window closes
        controller.onClose = { [weak self] in
            self?.windowController = nil
        }
    }
}

/// Window controller for the batch sanitize panel.
@MainActor
final class BatchSanitizeWindowController: NSWindowController {
    var onClose: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    convenience init() {
        self.init(viewModel: BatchSanitizeViewModel())
    }

    convenience init(viewModel: BatchSanitizeViewModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sanitize Folder"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)

        let contentView = BatchSanitizeSheet(viewModel: viewModel)
        window.contentView = NSHostingView(rootView: contentView)

        // Handle close
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onClose?()
            }
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}

/// View model for batch sanitize operations.
@MainActor
final class BatchSanitizeViewModel: ObservableObject {
    @Published var inputFolderURL: URL?
    @Published var outputFolderURL: URL?
    @Published var selectedProfile: SanitizeProfile = SanitizeDefaults.shared.defaultProfile
    @Published var isRecursive: Bool = true
    @Published var overwrite: Bool = false

    @Published var isRunning: Bool = false
    @Published var isCancelled: Bool = false
    @Published var isPreparingEvidence: Bool = false
    @Published var progress: BatchSanitizeProgress?
    @Published var report: BatchSanitizeReport?
    @Published var evidenceManifest: BatchCleanupEvidenceManifest?
    @Published var errorMessage: String?

    // Security-scoped access tokens
    private var inputAccessToken: Bool = false
    private var outputAccessToken: Bool = false

    var canStart: Bool {
        guard let input = inputFolderURL, let output = outputFolderURL else {
            return false
        }
        // Validate output ≠ input
        if input.standardizedFileURL == output.standardizedFileURL {
            return false
        }
        // Validate output not inside input when recursive
        if isRecursive {
            let inputPath = input.standardizedFileURL.resolvingSymlinksInPath().path
            let outputPath = output.standardizedFileURL.resolvingSymlinksInPath().path
            let inputPrefix = inputPath.hasSuffix("/") ? inputPath : inputPath + "/"
            if outputPath.hasPrefix(inputPrefix) {
                return false
            }
        }
        return true
    }

    var validationError: String? {
        guard inputFolderURL != nil else { return nil }
        guard outputFolderURL != nil else { return nil }

        if inputFolderURL?.standardizedFileURL == outputFolderURL?.standardizedFileURL {
            return "Output folder cannot be the same as input folder"
        }

        if isRecursive, let input = inputFolderURL, let output = outputFolderURL {
            let inputPath = input.standardizedFileURL.resolvingSymlinksInPath().path
            let outputPath = output.standardizedFileURL.resolvingSymlinksInPath().path
            let inputPrefix = inputPath.hasSuffix("/") ? inputPath : inputPath + "/"
            if outputPath.hasPrefix(inputPrefix) {
                return "Output folder cannot be inside input folder when recursive mode is enabled"
            }
        }

        return nil
    }

    func selectInputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder containing PDFs you want to inspect and sanitize"
        panel.prompt = "Select Source Folder"

        if panel.runModal() == .OK, let url = panel.url {
            inputFolderURL = url
        }
    }

    func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save the reviewed outbound copies"
        panel.prompt = "Select Outbound Folder"

        if panel.runModal() == .OK, let url = panel.url {
            outputFolderURL = url
        }
    }

    func startBatch() {
        guard let inputURL = inputFolderURL, let outputURL = outputFolderURL else {
            return
        }

        isRunning = true
        isCancelled = false
        isPreparingEvidence = false
        progress = nil
        report = nil
        evidenceManifest = nil
        errorMessage = nil

        // Start security-scoped access
        inputAccessToken = inputURL.startAccessingSecurityScopedResource()
        outputAccessToken = outputURL.startAccessingSecurityScopedResource()

        let profile = selectedProfile
        let recursive = isRecursive
        let overwrite = overwrite

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let plan = try BatchSanitizePlanner.plan(
                    inputDir: inputURL,
                    outputDir: outputURL,
                    recursive: recursive,
                    overwrite: overwrite
                )

                let result = BatchSanitizer.run(
                    plan: plan,
                    profile: profile,
                    dryRun: false,
                    progress: { progress in
                        DispatchQueue.main.async {
                            self?.progress = progress
                        }
                    },
                    shouldCancel: {
                        if Thread.isMainThread {
                            return MainActor.assumeIsolated { self?.isCancelled ?? false }
                        }
                        return DispatchQueue.main.sync {
                            MainActor.assumeIsolated { self?.isCancelled ?? false }
                        }
                    }
                )

                DispatchQueue.main.async {
                    self?.isPreparingEvidence = true
                }
                let evidenceManifest = BatchCleanupEvidenceBuilder.build(
                    plan: plan,
                    report: result
                )

                DispatchQueue.main.async {
                    self?.report = result
                    self?.evidenceManifest = evidenceManifest
                    self?.isPreparingEvidence = false
                    self?.isRunning = false
                    self?.endSecurityScopedAccess()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = error.localizedDescription
                    self?.isPreparingEvidence = false
                    self?.isRunning = false
                    self?.endSecurityScopedAccess()
                }
            }
        }
    }

    func cancel() {
        isCancelled = true
    }

    private func endSecurityScopedAccess() {
        if inputAccessToken, let url = inputFolderURL {
            url.stopAccessingSecurityScopedResource()
            inputAccessToken = false
        }
        if outputAccessToken, let url = outputFolderURL {
            url.stopAccessingSecurityScopedResource()
            outputAccessToken = false
        }
    }
}

/// SwiftUI view for batch sanitize configuration and progress.
struct BatchSanitizeSheet: View {
    @ObservedObject var viewModel: BatchSanitizeViewModel
    @State private var selectedEvidenceEntry: BatchCleanupEvidenceManifest.FileEntry?
    @State private var evidenceExportError: String?
    @State private var isFileEvidenceExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                // Configuration Section
                if !viewModel.isRunning, viewModel.report == nil {
                    configurationSection
                }

                // Progress Section
                if viewModel.isRunning {
                    progressSection
                }

                // Results Section
                if let report = viewModel.report {
                    resultsSection(report: report)
                }

                // Error Section
                if let error = viewModel.errorMessage {
                    errorSection(error: error)
                }

                // Action Buttons
                actionButtons
            }
            .padding(20)
        }
        .frame(minWidth: 600, minHeight: 580)
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .sheet(item: $selectedEvidenceEntry) { entry in
            if let evidence = entry.evidence {
                CleanupEvidenceSheet(evidence: evidence)
            }
        }
        .alert("Evidence Export Failed", isPresented: Binding(
            get: { evidenceExportError != nil },
            set: {
                if !$0 {
                    evidenceExportError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(evidenceExportError ?? "Unknown error")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Batch cleanup station")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.support)
            Text("Sanitize a folder into a safer outbound set")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.primaryText)
            Text("Choose the source, destination, and profile, then review a clear processed/skipped/failed receipt before handoff.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.secondaryText)
        }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Configuration", detail: "Select the source, outbound folder, and cleanup profile for this run.")

            // Input Folder
            HStack {
                Text("Source Folder")
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .frame(width: 100, alignment: .trailing)

                Text(viewModel.inputFolderURL?.path ?? "Not selected")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(viewModel.inputFolderURL == nil ? AppTheme.Colors.secondaryText : AppTheme.Colors.primaryText)

                Button("Choose…") {
                    viewModel.selectInputFolder()
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            // Output Folder
            HStack {
                Text("Outbound Folder")
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .frame(width: 100, alignment: .trailing)

                Text(viewModel.outputFolderURL?.path ?? "Not selected")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(viewModel.outputFolderURL == nil ? AppTheme.Colors.secondaryText : AppTheme.Colors.primaryText)

                Button("Choose…") {
                    viewModel.selectOutputFolder()
                }
                .buttonStyle(SecondaryButtonStyle())
            }

            Divider()

            // Profile
            HStack {
                Text("Profile")
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .frame(width: 100, alignment: .trailing)

                Picker("Profile", selection: $viewModel.selectedProfile) {
                    Text("Privacy Clean (Rasterize)").tag(SanitizeProfile.privacyClean)
                    Text("Light Clean (Searchable)").tag(SanitizeProfile.lightClean)
                    Text("Keep Editable (Forms OK)").tag(SanitizeProfile.keepEditable)
                }
                .labelsHidden()
                .frame(maxWidth: 250)
            }

            // Options
            HStack {
                Text("Options")
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .frame(width: 100, alignment: .trailing)

                Toggle("Include subdirectories", isOn: $viewModel.isRecursive)

                Toggle("Overwrite existing", isOn: $viewModel.overwrite)
            }

            // Validation error
            if let error = viewModel.validationError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(AppTheme.Colors.warning)
                    Text(error)
                        .foregroundColor(AppTheme.Colors.warning)
                        .font(.caption)
                }
                .padding(.top, 4)
            }
        }
        .cardStyle()
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                viewModel.isPreparingEvidence ? "Preparing evidence" : "Processing",
                detail: viewModel.isPreparingEvidence
                    ? "Verifying the completed outbound copies before folder access closes."
                    : "The current batch run is preparing reviewed outbound copies."
            )

            if viewModel.isPreparingEvidence {
                ProgressView()
                    .progressViewStyle(.linear)
                Text("Calculating file identities, page facts, metadata labels, and verdicts.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            } else if let progress = viewModel.progress {
                ProgressView(value: progress.fraction) {
                    Text("\(progress.currentFile) of \(progress.totalFiles)")
                }

                Text(progress.currentPath)
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(progress.isSkipping ? "This file is being skipped because an outbound copy already exists." : "This file is being sanitized into the outbound set now.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .cardStyle()
    }

    private func resultsSection(report: BatchSanitizeReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Run Receipt", detail: "Review the outcome before handing the outbound folder off.")

            HStack(spacing: 12) {
                statCard(value: "\(report.processed)", label: "Processed", color: AppTheme.Colors.success)
                statCard(value: "\(report.skipped)", label: "Skipped", color: AppTheme.Colors.warning)
                statCard(value: "\(report.failed)", label: "Failed", color: AppTheme.Colors.error)
                statCard(value: formatDuration(ms: report.totalElapsedMs), label: "Total Time", color: AppTheme.Colors.support)
            }

            VStack(alignment: .leading, spacing: 10) {
                evidenceRow("Profile", value: profileLabel(report.profile))
                evidenceRow("Input folder", value: report.inputDirectory)
                evidenceRow("Output folder", value: report.outputDirectory)
                evidenceRow("Traversal", value: report.recursive ? "Recursive" : "Top-level only")
                evidenceRow("Searchability", value: searchableSummary(report))

                if report.failed > 0 {
                    Divider()
                    Label("Some files failed to process. Check file permissions or PDF validity before sharing the output folder.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.warning)
                }

                if let failedNames = failedFileSummary(report), !failedNames.isEmpty {
                    Divider()
                    Text("Failed files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.paperText)
                    Text(failedNames)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.paperText.opacity(0.78))
                }
            }
            .paperPanelStyle()

            if let manifest = viewModel.evidenceManifest {
                batchEvidenceSection(manifest)
            }

            HStack(spacing: 12) {
                Button("Open Outbound Folder") {
                    if let url = viewModel.outputFolderURL {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(SecondaryButtonStyle())

                if let manifest = viewModel.evidenceManifest {
                    Button("Export Evidence…") {
                        exportEvidence(manifest)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if report.failed == 0, report.skipped == 0 {
                    Text("Receipt looks clean.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.support)
                } else if report.failed == 0 {
                    Text("Run completed without failures. Review skipped files before handoff.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.support)
                }
            }
        }
        .cardStyle()
    }

    private func batchEvidenceSection(_ manifest: BatchCleanupEvidenceManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleanup Evidence")
                        .font(.headline)
                    Text("Privacy-safe file receipts prepared before folder access closed.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.secondaryText)
                }
                Spacer()
                Label(verdictTitle(manifest.verdict), systemImage: verdictIcon(manifest.verdict))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(verdictColor(manifest.verdict))
            }

            HStack(spacing: 12) {
                statCard(value: "\(manifest.passedCount)", label: "Passed", color: AppTheme.Colors.success)
                statCard(value: "\(manifest.reviewRequiredCount)", label: "Review", color: AppTheme.Colors.warning)
                statCard(value: "\(manifest.failedCount)", label: "Failed", color: AppTheme.Colors.error)
            }

            Button {
                withAnimation(AppTheme.Motion.panelShift) {
                    isFileEvidenceExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isFileEvidenceExpanded ? 90 : 0))
                    Text("File evidence (\(manifest.files.count))")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .accessibilityIdentifier("batch-evidence-disclosure")
            .accessibilityValue(isFileEvidenceExpanded ? "Expanded" : "Collapsed")

            if isFileEvidenceExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(manifest.files) { entry in
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: verdictIcon(entry.verdict))
                                .foregroundStyle(verdictColor(entry.verdict))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.fileName)
                                    .font(.caption.weight(.semibold))
                                Text(entryDetail(entry))
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.Colors.secondaryText)
                            }
                            Spacer()
                            if entry.evidence != nil {
                                Button("View Evidence") {
                                    selectedEvidenceEntry = entry
                                }
                                .buttonStyle(.link)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(12)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius, style: .continuous))
    }

    private func errorSection(error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(AppTheme.Colors.error)
                Text("Run issue")
                    .font(.headline)
                    .foregroundStyle(AppTheme.Colors.primaryText)
            }
            Text(error)
                .foregroundColor(AppTheme.Colors.secondaryText)
        }
        .cardStyle()
    }

    private var actionButtons: some View {
        HStack {
            Spacer()

            if viewModel.isRunning {
                Button("Cancel") {
                    viewModel.cancel()
                }
                .buttonStyle(SecondaryButtonStyle())
            } else if viewModel.report != nil {
                Button("Done") {
                    // Close window
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Start Run") {
                    viewModel.startBatch()
                }
                .buttonStyle(PrimaryButtonStyle(isDisabled: !viewModel.canStart))
                .disabled(!viewModel.canStart)
                .keyboardShortcut(.defaultAction)
            }
        }
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

    private func statCard(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(AppTheme.Colors.cardBackground)
        .cornerRadius(AppTheme.Metrics.cardCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }

    private func evidenceRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.paperText.opacity(0.72))
                .frame(width: 108, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.paperText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func profileLabel(_ profile: SanitizeProfile) -> String {
        switch profile {
        case .privacyClean:
            "Privacy Clean"
        case .lightClean:
            "Light Clean"
        case .keepEditable:
            "Keep Editable"
        }
    }

    private func exportEvidence(_ manifest: BatchCleanupEvidenceManifest) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "batch-cleanup-evidence.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BatchCleanupEvidenceWriter.writeJSON(manifest, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            evidenceExportError = error.localizedDescription
        }
    }

    private func entryDetail(_ entry: BatchCleanupEvidenceManifest.FileEntry) -> String {
        switch entry.reason {
        case .existingOutputNotEvaluated:
            "Skipped · existing output was not evaluated"
        case .sanitizeFailed:
            "Failed · no private error details included"
        case .notProcessed:
            "Not processed · run stopped before this file"
        case .evidenceUnavailable:
            "Processed · evidence unavailable, review manually"
        case nil:
            "Processed · \(verdictTitle(entry.verdict))"
        }
    }

    private func verdictTitle(_ verdict: CleanupEvidenceVerdict) -> String {
        switch verdict {
        case .passed: "Passed"
        case .reviewRequired: "Review required"
        case .failed: "Failed"
        }
    }

    private func verdictIcon(_ verdict: CleanupEvidenceVerdict) -> String {
        switch verdict {
        case .passed: "checkmark.shield.fill"
        case .reviewRequired: "exclamationmark.triangle.fill"
        case .failed: "xmark.shield.fill"
        }
    }

    private func verdictColor(_ verdict: CleanupEvidenceVerdict) -> Color {
        switch verdict {
        case .passed: AppTheme.Colors.success
        case .reviewRequired: AppTheme.Colors.warning
        case .failed: AppTheme.Colors.error
        }
    }

    private func searchableSummary(_ report: BatchSanitizeReport) -> String {
        let searchable = report.files.count(where: { $0.status == .processed && $0.searchableText == true })
        let nonSearchable = report.files.count(where: { $0.status == .processed && $0.searchableText == false })
        if report.processed == 0 {
            return report.skipped > 0 ? "Not evaluated in this run; skipped files kept prior outputs." : "Not evaluated in this run."
        }
        let processedSummary = "\(searchable) searchable, \(nonSearchable) non-searchable in this run"
        if report.skipped > 0 {
            return "\(processedSummary); \(report.skipped) skipped"
        }
        return processedSummary
    }

    private func failedFileSummary(_ report: BatchSanitizeReport) -> String? {
        let failed = report.files.filter { $0.status == .failed }.map(\.input)
        guard !failed.isEmpty else { return nil }
        let shown = failed.prefix(5).joined(separator: ", ")
        if failed.count > 5 {
            return "\(shown), +\(failed.count - 5) more"
        }
        return shown
    }

    private func formatDuration(ms: Int) -> String {
        let seconds = Double(ms) / 1000.0
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds / 60)
            let remainingSeconds = Int(seconds) % 60
            return "\(minutes)m \(remainingSeconds)s"
        }
    }
}
