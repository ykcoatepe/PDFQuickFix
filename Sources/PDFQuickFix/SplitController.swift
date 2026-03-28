import Foundation
import Combine
import AppKit
import PDFQuickFixKit

enum SplitUIMode: Int, CaseIterable, Codable {
    case maxPagesPerFile
    case numberOfParts
    case approxSizeMB
    case explicitBreaks
    case outlineChapters

    var title: String {
        switch self {
        case .maxPagesPerFile: return "By max pages"
        case .numberOfParts: return "By parts"
        case .approxSizeMB: return "By size"
        case .explicitBreaks: return "By page breaks"
        case .outlineChapters: return "By chapters"
        }
    }
}

enum SplitControllerError: LocalizedError {
    case cancelled
    case noPDFsInFolder(URL)
    case invalidSettings(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Operation cancelled."
        case .noPDFsInFolder(let url):
            return "No PDF files were found in \(url.lastPathComponent)."
        case .invalidSettings(let message):
            return message
        }
    }
}

@MainActor
final class SplitController: ObservableObject {
    @Published var sourceURL: URL?
    @Published var destinationURL: URL?

    @Published var mode: SplitUIMode = .maxPagesPerFile
    @Published var maxPagesPerFile: Int = 500
    @Published var numberOfParts: Int = 2
    @Published var approxSizeMB: Double = 50
    @Published var explicitBreaksText: String = "1"
    @Published var applyToAllPDFsInFolder: Bool = false

    @Published private(set) var presets: [SplitJobPreset] = []
    @Published private(set) var history: [SplitJobRecord] = []

    @Published var isWorking: Bool = false
    @Published var status: String = "Ready"
    @Published var progressText: String?
    @Published var progressValue: Double?
    @Published var lastOutputFiles: [URL] = []

    private let defaults: UserDefaults
    private let bookmarking: Bookmarking
    private var currentTask: Task<Void, Never>?
    private var sourceAccess: SecurityScopedAccess?
    private var destinationAccess: SecurityScopedAccess?

    private let presetsKey = "SplitController.presets"
    private let historyKey = "SplitController.history"

    init(defaults: UserDefaults = .standard, bookmarking: Bookmarking = SystemBookmarking()) {
        self.defaults = defaults
        self.bookmarking = bookmarking
        presets = CodableUserDefaultsStore.loadArray([SplitJobPreset].self, key: presetsKey, defaults: defaults)
        history = CodableUserDefaultsStore.loadArray([SplitJobRecord].self, key: historyKey, defaults: defaults)
    }

    deinit {
        currentTask?.cancel()
    }

    var canSplit: Bool {
        guard sourceURL != nil else { return false }
        switch mode {
        case .maxPagesPerFile:
            return maxPagesPerFile > 0
        case .numberOfParts:
            return numberOfParts > 1
        case .approxSizeMB:
            return approxSizeMB > 0
        case .explicitBreaks:
            return !explicitBreaksText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .outlineChapters:
            return true
        }
    }

    func addSourceURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }
        if sourceURL == nil {
            sourceURL = first
        }
        if destinationURL == nil {
            destinationURL = first.deletingLastPathComponent()
        }
        status = "Ready"
    }

    func removeSource(at offsets: IndexSet) {
        guard offsets.contains(0) else { return }
        sourceURL = nil
    }

    func clearSources() {
        sourceURL = nil
        destinationURL = nil
        sourceAccess = nil
        destinationAccess = nil
        lastOutputFiles = []
    }

    func setSource(url: URL) {
        sourceURL = url
        destinationURL = url.deletingLastPathComponent()
        sourceAccess = SecurityScopedAccess(url: url)
        destinationAccess = destinationURL.map(SecurityScopedAccess.init(url:))
        status = "Ready"
        progressText = nil
        progressValue = nil
        lastOutputFiles = []
    }

    func setDestination(url: URL) {
        destinationURL = url
        destinationAccess = SecurityScopedAccess(url: url)
    }

    func cancel() {
        currentTask?.cancel()
        if isWorking {
            status = "Cancelling…"
        }
    }

    func savePresetFromPrompt() {
        let defaultName = "Split Preset"
        guard let name = promptForText(title: "Save Split Preset",
                                       message: "Choose a name for the current split settings.",
                                       defaultValue: defaultName) else { return }
        savePreset(named: name)
    }

    func duplicateCurrentSettings() {
        let defaultName = "Copy of Split Preset"
        guard let name = promptForText(title: "Duplicate Split Settings",
                                       message: "Save the current split settings as a new preset.",
                                       defaultValue: defaultName) else { return }
        savePreset(named: name)
    }

    func savePreset(named name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let preset = SplitJobPreset(id: UUID(), name: cleaned, createdAt: Date(), settings: currentSettings())
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            presets[index] = preset
        } else {
            presets.insert(preset, at: 0)
        }
        persistPresets()
    }

    func applyPreset(_ preset: SplitJobPreset) {
        apply(settings: preset.settings)
        status = "Preset applied: \(preset.name)"
    }

    func applyHistory(_ record: SplitJobRecord) {
        apply(settings: record.settings)
        status = "Settings restored from history."
    }

    func split() {
        guard !isWorking else { return }
        guard let source = sourceURL else {
            status = "Select a PDF file first."
            return
        }
        guard let _ = makeSplitMode() else {
            status = "Invalid split settings."
            return
        }

        let destination = destinationURL ?? source.deletingLastPathComponent()
        let settings = currentSettings()
        let sourceAccess = self.sourceAccess
        let destinationAccess = self.destinationAccess

        isWorking = true
        status = "Splitting…"
        progressText = nil
        progressValue = nil
        lastOutputFiles = []

        currentTask = Task.detached(priority: .userInitiated) { [weak self, sourceAccess, destinationAccess] in
            guard let self else { return }
            _ = sourceAccess
            _ = destinationAccess
            do {
                let result = try self.executeSplit(
                    settings: settings,
                    sourceURL: source,
                    destinationURL: destination,
                    shouldCancel: { Task.isCancelled },
                    progress: { processed, total in
                        Task { @MainActor in
                            self.progressText = "Processed \(processed)/\(total) pages"
                            self.progressValue = total > 0 ? Double(processed) / Double(total) : nil
                        }
                    }
                )
                await MainActor.run {
                    self.finishSplit(result: result, destinationURL: destination, settings: settings)
                }
            } catch {
                await MainActor.run {
                    self.finishSplitFailure(error: error)
                }
            }
        }
    }

    private struct SplitExecutionResult {
        let outputFiles: [URL]
        let fileCount: Int
        let sourceDescription: String
        let destinationFolder: String
        let warnings: [String]
    }

    private nonisolated func executeSplit(settings: SplitJobSettings,
                                          sourceURL: URL,
                                          destinationURL: URL,
                                          shouldCancel: @escaping () -> Bool,
                                          progress: ((Int, Int) -> Void)?) throws -> SplitExecutionResult {
        if shouldCancel() { throw SplitControllerError.cancelled }

        let destination = destinationURL
        let splitter = PDFSplitter()
        if settings.applyToAllPDFsInFolder {
            let folder = sourceURL.deletingLastPathComponent()
            let urls = try FileManager.default.contentsOfDirectory(at: folder,
                                                                   includingPropertiesForKeys: nil,
                                                                   options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.lowercased() == "pdf" }
            guard !urls.isEmpty else { throw SplitControllerError.noPDFsInFolder(folder) }

            var outputs: [URL] = []
            var warnings: [String] = []

            for fileURL in urls {
                if shouldCancel() { throw SplitControllerError.cancelled }
                do {
                    let repairedURL = try repairInputIfNeeded(fileURL)
                    let mode = try makeMode(from: settings)
                    let splitResult = try splitter.split(
                        options: PDFSplitOptions(sourceURL: repairedURL,
                                                 destinationDirectory: destination,
                                                 mode: mode),
                        progress: { processed, total in
                            progress?(processed, total)
                        },
                        shouldCancel: shouldCancel
                    )
                    outputs.append(contentsOf: splitResult.outputFiles)
                } catch is CancellationError {
                    throw SplitControllerError.cancelled
                } catch let splitError as SplitControllerError {
                    if case .cancelled = splitError {
                        throw splitError
                    }
                    warnings.append(batchWarning(for: fileURL, error: splitError))
                } catch let splitError as PDFSplitError {
                    if case .cancelled = splitError {
                        throw SplitControllerError.cancelled
                    }
                    warnings.append(batchWarning(for: fileURL, error: splitError))
                } catch {
                    warnings.append(batchWarning(for: fileURL, error: error))
                }
            }

            return SplitExecutionResult(
                outputFiles: outputs,
                fileCount: urls.count,
                sourceDescription: folder.lastPathComponent,
                destinationFolder: destination.lastPathComponent,
                warnings: warnings
            )
        }

        let repairedURL = try repairInputIfNeeded(sourceURL)
        let mode = try makeMode(from: settings)
        let splitResult = try splitter.split(
            options: PDFSplitOptions(sourceURL: repairedURL,
                                     destinationDirectory: destination,
                                     mode: mode),
            progress: progress,
            shouldCancel: shouldCancel
        )
        return SplitExecutionResult(
            outputFiles: splitResult.outputFiles,
            fileCount: 1,
            sourceDescription: sourceURL.lastPathComponent,
            destinationFolder: destination.lastPathComponent,
            warnings: []
        )
    }

    private func finishSplit(result: SplitExecutionResult,
                             destinationURL: URL,
                             settings: SplitJobSettings) {
        isWorking = false
        currentTask = nil
        lastOutputFiles = result.outputFiles
        progressText = nil
        progressValue = nil
        if result.outputFiles.isEmpty {
            status = "No output files were produced."
        } else {
            status = "Done. \(result.outputFiles.count) file(s) written to \(destinationURL.lastPathComponent)."
        }
        appendHistory(
            SplitJobRecord(
                id: UUID(),
                date: Date(),
                settings: settings,
                sourceDescription: result.sourceDescription,
                modeDescription: describeMode(from: settings),
                fileCount: result.fileCount,
                outputCount: result.outputFiles.count,
                destinationFolder: result.destinationFolder,
                errorSummary: result.warnings.isEmpty ? nil : result.warnings.joined(separator: " | ")
            )
        )
    }

    private func finishSplitFailure(error: Error) {
        isWorking = false
        currentTask = nil
        progressText = nil
        progressValue = nil
        if let splitError = error as? SplitControllerError, case .cancelled = splitError {
            status = "Split cancelled."
        } else {
            status = "Split failed: \(error.localizedDescription)"
        }
    }

    private func currentSettings() -> SplitJobSettings {
        let normalizedSourceURL = sourceURL?.standardizedFileURL
        let normalizedDestinationURL = destinationURL?.standardizedFileURL
        return SplitJobSettings(
            sourceURLString: normalizedSourceURL?.path,
            sourceBookmarkData: bookmarkData(for: sourceBookmarkURL(sourceURL: normalizedSourceURL)),
            destinationURLString: normalizedDestinationURL?.path,
            destinationBookmarkData: bookmarkData(for: normalizedDestinationURL),
            applyToAllPDFsInFolder: applyToAllPDFsInFolder,
            mode: mode,
            maxPagesPerFile: maxPagesPerFile,
            numberOfParts: numberOfParts,
            approxSizeMB: approxSizeMB,
            explicitBreaksText: explicitBreaksText
        )
    }

    private func apply(settings: SplitJobSettings) {
        mode = settings.mode
        maxPagesPerFile = settings.maxPagesPerFile
        numberOfParts = settings.numberOfParts
        approxSizeMB = settings.approxSizeMB
        explicitBreaksText = settings.explicitBreaksText
        applyToAllPDFsInFolder = settings.applyToAllPDFsInFolder
        sourceAccess = access(from: settings.sourceBookmarkData)
        destinationAccess = access(from: settings.destinationBookmarkData)
        sourceURL = resolvedURL(from: settings.sourceURLString) ?? sourceAccess?.url
        destinationURL = destinationAccess?.url ?? resolvedURL(from: settings.destinationURLString)
        progressText = nil
        progressValue = nil
        lastOutputFiles = []
    }

    private nonisolated func describeMode(from settings: SplitJobSettings) -> String {
        switch settings.mode {
        case .maxPagesPerFile:
            return "max \(settings.maxPagesPerFile) pages"
        case .numberOfParts:
            return "\(settings.numberOfParts) parts"
        case .approxSizeMB:
            return "~\(settings.approxSizeMB) MB"
        case .explicitBreaks:
            return "page breaks: \(settings.explicitBreaksText)"
        case .outlineChapters:
            return "outline chapters"
        }
    }

    private func makeSplitMode() -> PDFSplitMode? {
        try? makeMode(from: currentSettings())
    }

    private nonisolated func makeMode(from settings: SplitJobSettings) throws -> PDFSplitMode {
        switch settings.mode {
        case .maxPagesPerFile:
            guard settings.maxPagesPerFile > 0 else { throw SplitControllerError.invalidSettings("Max pages per file must be greater than zero.") }
            return .maxPagesPerPart(settings.maxPagesPerFile)
        case .numberOfParts:
            guard settings.numberOfParts > 1 else { throw SplitControllerError.invalidSettings("Number of parts must be greater than one.") }
            return .numberOfParts(settings.numberOfParts)
        case .approxSizeMB:
            guard settings.approxSizeMB > 0 else { throw SplitControllerError.invalidSettings("Approx. size must be greater than zero.") }
            return .approxTargetSizeMB(settings.approxSizeMB)
        case .explicitBreaks:
            let breaks = parseExplicitBreaks(from: settings.explicitBreaksText)
            guard !breaks.isEmpty else { throw SplitControllerError.invalidSettings("Enter at least one valid page break.") }
            return .explicitBreaks(breaks)
        case .outlineChapters:
            return .outlineChapters
        }
    }

    private nonisolated func parseExplicitBreaks(from text: String) -> [Int] {
        let separators = CharacterSet(charactersIn: ",; ")
        return text.components(separatedBy: separators)
            .compactMap { token -> Int? in
                let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                return Int(trimmed)
            }
    }

    private nonisolated func repairInputIfNeeded(_ url: URL) throws -> URL {
        do {
            return try PDFRepairService().repairIfNeeded(inputURL: url)
        } catch {
            return url
        }
    }

    private nonisolated func batchWarning(for fileURL: URL, error: Error) -> String {
        let detail: String
        switch error {
        case let splitError as PDFSplitError:
            switch splitError {
            case .cannotOpenSource:
                detail = "unreadable or invalid PDF"
            case .noPages:
                detail = "PDF has no pages"
            case .invalidMode(let message):
                detail = message
            case .writeFailed(let outputURL):
                detail = "failed to write \(outputURL.lastPathComponent)"
            case .cancelled:
                detail = "operation cancelled"
            }
        case let controllerError as SplitControllerError:
            switch controllerError {
            case .cancelled:
                detail = "operation cancelled"
            case .noPDFsInFolder:
                detail = "no PDFs found in folder"
            case .invalidSettings(let message):
                detail = message
            }
        default:
            detail = error.localizedDescription
        }
        return "Skipped \(fileURL.lastPathComponent): \(detail)."
    }

    private func sourceBookmarkURL(sourceURL: URL?) -> URL? {
        guard let sourceURL else { return nil }
        return applyToAllPDFsInFolder ? sourceURL.deletingLastPathComponent() : sourceURL
    }

    private func bookmarkData(for url: URL?) -> Data? {
        guard let url else { return nil }
        return try? bookmarking.bookmarkData(for: url, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func access(from bookmarkData: Data?) -> SecurityScopedAccess? {
        guard let bookmarkData,
              let result = try? bookmarking.resolveBookmarkData(bookmarkData,
                                                               options: .withSecurityScope,
                                                               relativeTo: nil) else {
            return nil
        }
        return SecurityScopedAccess(url: result.url)
    }

    private nonisolated func resolvedURL(from path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func appendHistory(_ record: SplitJobRecord) {
        history.insert(record, at: 0)
        if history.count > 100 {
            history.removeLast(history.count - 100)
        }
        persistHistory()
    }

    private func persistHistory() {
        CodableUserDefaultsStore.saveArray(history, key: historyKey, defaults: defaults)
    }

    private func persistPresets() {
        CodableUserDefaultsStore.saveArray(presets, key: presetsKey, defaults: defaults)
    }
}
