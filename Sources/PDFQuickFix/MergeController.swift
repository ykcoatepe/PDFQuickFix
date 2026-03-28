import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
struct MergeJobRecord: Identifiable {
    let id = UUID()
    let date: Date
    let sourceCount: Int
    let mergedDocumentCount: Int
    let mergedPageCount: Int
    let destinationFolder: String
    let outputFileName: String
    let skippedCount: Int
    let warningsSummary: String?
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
            }
        }
    }
    @Published var outlinePolicy: MergeOutlinePolicy = .addTopLevelPerSource
    @Published var metadataPolicy: MergeMetadataPolicy = .keepFirst

    @Published var isWorking: Bool = false
    @Published var status: String = "Ready"
    @Published var warnings: [String] = []
    @Published var history: [MergeJobRecord] = []
    @Published var lastOutputURL: URL?

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
        status = "Ready"
    }

    func removeSource(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard sourceURLs.indices.contains(index) else { continue }
            sourceURLs.remove(at: index)
        }
    }

    func clearSources() {
        sourceURLs = []
    }

    func moveSource(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.sorted().compactMap { sourceURLs.indices.contains($0) ? sourceURLs[$0] : nil }
        for index in offsets.sorted(by: >) {
            guard sourceURLs.indices.contains(index) else { continue }
            sourceURLs.remove(at: index)
        }
        let boundedDestination = max(0, min(destination, sourceURLs.count))
        sourceURLs.insert(contentsOf: moving, at: boundedDestination)
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
        }
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
        Task.detached(priority: .userInitiated) {
            do {
                let result = try withExtendedLifetime(outputSelection.access) {
                    try PDFMerge.merge(urls: inputURLs, outputURL: outputSelection.url, options: options)
                }
                await MainActor.run {
                    self.isWorking = false
                    self.lastOutputURL = result.outputURL
                    self.warnings = result.warnings
                    let warningSuffix = result.skippedSources.isEmpty ? "" : " (\(result.skippedSources.count) skipped)"
                    self.status = "Done. \(result.mergedPageCount) pages from \(result.mergedDocumentCount) documents\(warningSuffix)."
                    self.history.append(
                        MergeJobRecord(
                            date: Date(),
                            sourceCount: inputURLs.count,
                            mergedDocumentCount: result.mergedDocumentCount,
                            mergedPageCount: result.mergedPageCount,
                            destinationFolder: selectedDestinationFolderURL.lastPathComponent,
                            outputFileName: result.outputURL.lastPathComponent,
                            skippedCount: result.skippedSources.count,
                            warningsSummary: result.warnings.isEmpty ? nil : result.warnings.joined(separator: " | ")
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.status = "Merge failed: \(error.localizedDescription)"
                    self.warnings = []
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
}
