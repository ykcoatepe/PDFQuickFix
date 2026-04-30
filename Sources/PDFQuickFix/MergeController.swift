import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum MergeControllerError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Operation cancelled."
        }
    }
}

@MainActor
final class MergeController: ObservableObject {
    @Published var sourceURLs: [URL] = []
    @Published var destinationFolderURL: URL?
    @Published var outputFileName: String = "Merged.pdf"

    @Published var insertBlankPageBetweenDocuments: Bool = false
    @Published var skipUnreadableSources: Bool = true
    @Published var deduplicateSources: Bool = false {
        didSet {
            if deduplicateSources {
                sourceURLs = deduplicated(sourceURLs)
                rebuildSourceAccesses()
            }
        }
    }

    @Published var outlinePolicy: MergeOutlinePolicy = .addTopLevelPerSource
    @Published var metadataPolicy: MergeMetadataPolicy = .keepFirst

    @Published private(set) var presets: [MergeJobPreset] = []
    @Published private(set) var history: [MergeJobRecord] = []

    @Published var isWorking: Bool = false
    @Published var status: String = "Ready"
    @Published var warnings: [String] = []
    @Published var lastOutputURL: URL?

    private let defaults: UserDefaults
    private let bookmarking: Bookmarking
    private let presetsKey = "MergeController.presets"
    private let historyKey = "MergeController.history"
    private let mergeEngine = PDFMerge.self
    private var currentTask: Task<Void, Never>?
    private var sourceAccesses: [SecurityScopedAccess] = []
    private var destinationAccess: SecurityScopedAccess?

    init(defaults: UserDefaults = .standard, bookmarking: Bookmarking = SystemBookmarking()) {
        self.defaults = defaults
        self.bookmarking = bookmarking
        presets = CodableUserDefaultsStore.loadArray([MergeJobPreset].self, key: presetsKey, defaults: defaults)
        history = CodableUserDefaultsStore.loadArray([MergeJobRecord].self, key: historyKey, defaults: defaults)
    }

    deinit {
        currentTask?.cancel()
    }

    var canMerge: Bool {
        sourceURLs.count >= 2 && destinationFolderURL != nil && !outputFileNameTrimmed.isEmpty
    }

    var outputFileNameTrimmed: String {
        outputFileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func addSourceURLs(_ urls: [URL]) {
        let candidates = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !candidates.isEmpty else { return }

        if sourceURLs.isEmpty {
            destinationFolderURL = candidates[0].deletingLastPathComponent()
        }

        sourceURLs.append(contentsOf: candidates)
        if deduplicateSources {
            sourceURLs = deduplicated(sourceURLs)
        }
        rebuildSourceAccesses()
        if let destinationFolderURL {
            destinationAccess = SecurityScopedAccess(url: destinationFolderURL)
        }
        status = "Ready"
    }

    func removeSource(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard sourceURLs.indices.contains(index) else { continue }
            sourceURLs.remove(at: index)
        }
        rebuildSourceAccesses()
    }

    func clearSources() {
        sourceURLs = []
        sourceAccesses = []
    }

    func moveSource(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().compactMap { sourceURLs.indices.contains($0) ? sourceURLs[$0] : nil }
        let removedBeforeDestination = offsets.count(where: { $0 < destination })
        for index in offsets.sorted(by: >) {
            guard sourceURLs.indices.contains(index) else { continue }
            sourceURLs.remove(at: index)
        }
        let adjustedDestination = destination - removedBeforeDestination
        let boundedDestination = max(0, min(adjustedDestination, sourceURLs.count))
        sourceURLs.insert(contentsOf: moving, at: boundedDestination)
        rebuildSourceAccesses()
    }

    func chooseSources() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            addSourceURLs(panel.urls)
        }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            destinationFolderURL = url
            destinationAccess = SecurityScopedAccess(url: url)
        }
    }

    func cancel() {
        currentTask?.cancel()
        if isWorking {
            status = "Cancelling…"
        }
    }

    func savePresetFromPrompt() {
        guard let name = promptForText(title: "Save Merge Preset",
                                       message: "Choose a name for the current merge settings.",
                                       defaultValue: "Merge Preset") else { return }
        savePreset(named: name)
    }

    func duplicateCurrentSettings() {
        guard let name = promptForText(title: "Duplicate Merge Settings",
                                       message: "Save the current merge settings as a new preset.",
                                       defaultValue: "Copy of Merge Preset") else { return }
        savePreset(named: name)
    }

    func savePreset(named name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let preset = MergeJobPreset(id: UUID(), name: cleaned, createdAt: Date(), settings: currentSettings())
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            presets[index] = preset
        } else {
            presets.insert(preset, at: 0)
        }
        persistPresets()
    }

    func applyPreset(_ preset: MergeJobPreset) {
        apply(settings: preset.settings)
        status = "Preset applied: \(preset.name)"
    }

    func applyHistory(_ record: MergeJobRecord) {
        apply(settings: record.settings)
        status = "Settings restored from history."
    }

    func merge() {
        guard !isWorking else { return }
        guard sourceURLs.count >= 2 else {
            status = "Select at least 2 PDF files."
            return
        }
        guard let selectedDestinationFolderURL = destinationFolderURL else {
            status = "Select a destination folder."
            return
        }

        let options = PDFMergeOptions(
            insertBlankPageBetweenDocuments: insertBlankPageBetweenDocuments,
            skipUnreadableSources: skipUnreadableSources,
            deduplicateSources: deduplicateSources,
            outlinePolicy: outlinePolicy,
            metadataPolicy: metadataPolicy
        )
        let outputName = normalizedOutputFileName(from: outputFileNameTrimmed)
        let requestedOutputURL = selectedDestinationFolderURL.appendingPathComponent(outputName)
        let defaultOutputURL = uniqueOutputURL(for: requestedOutputURL)

        let outputSelection: QuickFixOutputSelection
        do {
            outputSelection = try resolveQuickFixOutputSelection(
                defaultOutputURL: defaultOutputURL,
                preferredOutputURL: defaultOutputURL,
                panelTitle: "Save Merged PDF"
            )
            if outputSelection.url.deletingLastPathComponent() != selectedDestinationFolderURL {
                destinationFolderURL = outputSelection.url.deletingLastPathComponent()
            }
        } catch QuickFixOutputSelectionError.cancelled {
            status = "Merge cancelled: output location not selected."
            return
        } catch {
            status = "Merge failed: \(error.localizedDescription)"
            return
        }

        isWorking = true
        status = "Merging…"
        warnings = []
        lastOutputURL = nil

        let inputURLs = sourceURLs
        let destinationFolder = outputSelection.url.deletingLastPathComponent()
        let settings = currentSettings(with: outputSelection.url)
        let outputAccess = outputSelection.access
        let sourceAccesses = sourceAccesses
        let destinationAccess = destinationAccess
        currentTask = Task.detached(priority: .userInitiated) { [weak self, outputAccess, sourceAccesses, destinationAccess] in
            guard let self else { return }
            _ = outputAccess
            _ = sourceAccesses
            _ = destinationAccess
            do {
                let result = try mergeEngine.merge(
                    urls: inputURLs,
                    outputURL: outputSelection.url,
                    options: options,
                    shouldCancel: { Task.isCancelled }
                )
                await MainActor.run {
                    self.finishMerge(
                        result: result,
                        settings: settings,
                        selectedDestinationFolderURL: destinationFolder
                    )
                }
            } catch {
                await MainActor.run {
                    self.finishMergeFailure(error: error)
                }
            }
        }
    }

    func revealOutputInFinder() {
        guard let lastOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutputURL])
    }

    private func deduplicated(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        unique.reserveCapacity(urls.count)
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    private func normalizedOutputFileName(from value: String) -> String {
        let trimmed = value.isEmpty ? "Merged.pdf" : value
        if trimmed.lowercased().hasSuffix(".pdf") {
            return trimmed
        }
        return "\(trimmed).pdf"
    }

    func uniqueOutputURL(for requestedURL: URL) -> URL {
        let directory = requestedURL.deletingLastPathComponent()
        let ext = requestedURL.pathExtension
        var stem = requestedURL.deletingPathExtension().lastPathComponent
        if stem.isEmpty {
            stem = "Merged"
        }

        let fm = FileManager.default
        var candidate = requestedURL
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let nextName = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            counter += 1
        }
        return candidate
    }

    func currentSettings(with outputURL: URL? = nil) -> MergeJobSettings {
        let destinationFolder = outputURL?.deletingLastPathComponent().standardizedFileURL ?? destinationFolderURL?.standardizedFileURL
        return MergeJobSettings(
            sourceURLStrings: sourceURLs.map(\.standardizedFileURL.path),
            sourceBookmarkData: sourceURLs.map { bookmarkData(for: $0.standardizedFileURL) },
            destinationFolderURLString: destinationFolder?.path,
            destinationFolderBookmarkData: bookmarkData(for: destinationFolder),
            outputFileName: outputURL?.lastPathComponent ?? (outputFileNameTrimmed.isEmpty ? "Merged.pdf" : outputFileNameTrimmed),
            insertBlankPageBetweenDocuments: insertBlankPageBetweenDocuments,
            skipUnreadableSources: skipUnreadableSources,
            deduplicateSources: deduplicateSources,
            outlinePolicy: outlinePolicy,
            metadataPolicy: metadataPolicy
        )
    }

    private func apply(settings: MergeJobSettings) {
        sourceAccesses = []
        sourceURLs = []
        for (index, path) in settings.sourceURLStrings.enumerated() {
            let bookmarkData = index < settings.sourceBookmarkData.count ? settings.sourceBookmarkData[index] : nil
            if let access = access(from: bookmarkData) {
                sourceAccesses.append(access)
                sourceURLs.append(access.url)
            } else if let url = resolvedURL(from: path) {
                sourceURLs.append(url)
            }
        }

        destinationAccess = access(from: settings.destinationFolderBookmarkData)
        destinationFolderURL = destinationAccess?.url ?? resolvedURL(from: settings.destinationFolderURLString)
        outputFileName = settings.outputFileName
        insertBlankPageBetweenDocuments = settings.insertBlankPageBetweenDocuments
        skipUnreadableSources = settings.skipUnreadableSources
        deduplicateSources = settings.deduplicateSources
        outlinePolicy = settings.outlinePolicy
        metadataPolicy = settings.metadataPolicy
        warnings = []
        lastOutputURL = nil
    }

    private func finishMerge(result: PDFMergeResult,
                             settings: MergeJobSettings,
                             selectedDestinationFolderURL: URL)
    {
        isWorking = false
        currentTask = nil
        lastOutputURL = result.outputURL
        warnings = result.warnings
        let warningSuffix = result.skippedSources.isEmpty ? "" : " (\(result.skippedSources.count) skipped)"
        status = "Done. \(result.mergedPageCount) pages from \(result.mergedDocumentCount) documents\(warningSuffix)."
        appendHistory(
            MergeJobRecord(
                id: UUID(),
                date: Date(),
                settings: settings,
                sourceCount: sourceURLs.count,
                mergedDocumentCount: result.mergedDocumentCount,
                mergedPageCount: result.mergedPageCount,
                destinationFolder: selectedDestinationFolderURL.lastPathComponent,
                outputFileName: result.outputURL.lastPathComponent,
                skippedCount: result.skippedSources.count,
                warningsSummary: result.warnings.isEmpty ? nil : result.warnings.joined(separator: " | ")
            )
        )
    }

    private func finishMergeFailure(error: Error) {
        isWorking = false
        currentTask = nil
        if isCancellationError(error) {
            status = "Merge cancelled."
        } else {
            status = "Merge failed: \(error.localizedDescription)"
        }
        warnings = []
    }

    private func appendHistory(_ record: MergeJobRecord) {
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

    private func rebuildSourceAccesses() {
        sourceAccesses = sourceURLs.map { SecurityScopedAccess(url: $0) }
    }

    private func bookmarkData(for url: URL?) -> Data? {
        guard let url else { return nil }
        return try? bookmarking.bookmarkData(for: url, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func access(from bookmarkData: Data?) -> SecurityScopedAccess? {
        guard let bookmarkData,
              let result = try? bookmarking.resolveBookmarkData(bookmarkData,
                                                                options: .withSecurityScope,
                                                                relativeTo: nil)
        else {
            return nil
        }
        return SecurityScopedAccess(url: result.url)
    }

    private func resolvedURL(from path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is MergeControllerError || error is CancellationError {
            return true
        }
        if let mergeError = error as? PDFMergeError, case .cancelled = mergeError {
            return true
        }
        return false
    }
}
