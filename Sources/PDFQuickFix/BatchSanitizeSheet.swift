import SwiftUI
import AppKit
import PDFQuickFixKit

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
final class BatchSanitizeWindowController: NSWindowController {
    var onClose: (() -> Void)?
    
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sanitize Folder"
        window.center()
        window.isReleasedWhenClosed = false
        
        self.init(window: window)
        
        let viewModel = BatchSanitizeViewModel()
        let contentView = BatchSanitizeSheet(viewModel: viewModel)
        window.contentView = NSHostingView(rootView: contentView)
        
        // Handle close
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onClose?()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
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
    @Published var progress: BatchSanitizeProgress?
    @Published var report: BatchSanitizeReport?
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
        panel.message = "Choose the folder containing PDFs to sanitize"
        panel.prompt = "Select Input Folder"
        
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
        panel.message = "Choose where to save sanitized PDFs"
        panel.prompt = "Select Output Folder"
        
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
        progress = nil
        report = nil
        errorMessage = nil
        
        // Start security-scoped access
        inputAccessToken = inputURL.startAccessingSecurityScopedResource()
        outputAccessToken = outputURL.startAccessingSecurityScopedResource()
        
        let profile = selectedProfile
        let recursive = isRecursive
        let overwrite = self.overwrite
        
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
                    self?.report = result
                    self?.isRunning = false
                    self?.endSecurityScopedAccess()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = error.localizedDescription
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Configuration Section
            if !viewModel.isRunning && viewModel.report == nil {
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
            
            Spacer()
            
            // Action Buttons
            actionButtons
        }
        .padding()
        .frame(minWidth: 450, minHeight: 350)
    }
    
    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Sanitize PDFs")
                .font(.headline)
            
            // Input Folder
            HStack {
                Text("Input Folder:")
                    .frame(width: 100, alignment: .trailing)
                
                Text(viewModel.inputFolderURL?.path ?? "Not selected")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(viewModel.inputFolderURL == nil ? .secondary : .primary)
                
                Button("Choose…") {
                    viewModel.selectInputFolder()
                }
            }
            
            // Output Folder
            HStack {
                Text("Output Folder:")
                    .frame(width: 100, alignment: .trailing)
                
                Text(viewModel.outputFolderURL?.path ?? "Not selected")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(viewModel.outputFolderURL == nil ? .secondary : .primary)
                
                Button("Choose…") {
                    viewModel.selectOutputFolder()
                }
            }
            
            Divider()
            
            // Profile
            HStack {
                Text("Profile:")
                    .frame(width: 100, alignment: .trailing)
                
                Picker("", selection: $viewModel.selectedProfile) {
                    Text("Privacy Clean (Rasterize)").tag(SanitizeProfile.privacyClean)
                    Text("Light Clean (Searchable)").tag(SanitizeProfile.lightClean)
                    Text("Keep Editable (Forms OK)").tag(SanitizeProfile.keepEditable)
                }
                .labelsHidden()
                .frame(maxWidth: 250)
            }
            
            // Options
            HStack {
                Text("Options:")
                    .frame(width: 100, alignment: .trailing)
                
                Toggle("Include subdirectories", isOn: $viewModel.isRecursive)
                
                Toggle("Overwrite existing", isOn: $viewModel.overwrite)
            }
            
            // Validation error
            if let error = viewModel.validationError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                .padding(.top, 4)
            }
        }
    }
    
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Processing…")
                .font(.headline)
            
            if let progress = viewModel.progress {
                ProgressView(value: progress.fraction) {
                    Text("\(progress.currentFile) of \(progress.totalFiles)")
                }
                
                Text(progress.currentPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
    }
    
    private func resultsSection(report: BatchSanitizeReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Completed")
                .font(.headline)
            
            HStack(spacing: 20) {
                VStack {
                    Text("\(report.processed)")
                        .font(.title)
                        .foregroundColor(.green)
                    Text("Processed")
                        .font(.caption)
                }
                
                VStack {
                    Text("\(report.skipped)")
                        .font(.title)
                        .foregroundColor(.orange)
                    Text("Skipped")
                        .font(.caption)
                }
                
                VStack {
                    Text("\(report.failed)")
                        .font(.title)
                        .foregroundColor(.red)
                    Text("Failed")
                        .font(.caption)
                }
                
                Spacer()
                
                VStack(alignment: .trailing) {
                    Text(formatDuration(ms: report.totalElapsedMs))
                        .font(.title2)
                    Text("Total Time")
                        .font(.caption)
                }
            }
            .padding(.vertical, 8)
            
            if report.failed > 0 {
                Text("Some files failed to process. Check file permissions and PDF validity.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Button("Open Output Folder") {
                if let url = viewModel.outputFolderURL {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    private func errorSection(error: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Error")
                    .font(.headline)
            }
            Text(error)
                .foregroundColor(.secondary)
        }
    }
    
    private var actionButtons: some View {
        HStack {
            Spacer()
            
            if viewModel.isRunning {
                Button("Cancel") {
                    viewModel.cancel()
                }
            } else if viewModel.report != nil {
                Button("Done") {
                    // Close window
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Start") {
                    viewModel.startBatch()
                }
                .disabled(!viewModel.canStart)
                .keyboardShortcut(.defaultAction)
            }
        }
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
