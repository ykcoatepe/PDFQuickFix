import Foundation
import Combine
import PDFQuickFixKit

struct SplitJobRecord: Identifiable {
    let id = UUID()
    let date: Date
    let sourceDescription: String
    let modeDescription: String
    let fileCount: Int           // number of input PDFs processed
    let outputCount: Int         // total output PDF files created
    let destinationFolder: String
    let errorSummary: String?
}

enum SplitUIMode: Int, CaseIterable {
    case maxPagesPerFile
    case numberOfParts
    case approxSizeMB        // approximate MB target per part
    case explicitBreaks      // comma-separated start pages
    case outlineChapters

    var title: String {
        switch self {
        case .maxPagesPerFile: return "By max pages"
        case .numberOfParts:   return "By parts"
        case .approxSizeMB:    return "By size"
        case .explicitBreaks:  return "By page breaks"
        case .outlineChapters: return "By chapters"
        }
    }
}

final class SplitController: ObservableObject {

    @Published var sourceURL: URL?
    @Published var destinationURL: URL?

    @Published var mode: SplitUIMode = .maxPagesPerFile
    @Published var maxPagesPerFile: Int = 500
    @Published var numberOfParts: Int = 2
    @Published var approxSizeMB: Double = 50
    @Published var explicitBreaksText: String = "1"
    @Published var applyToAllPDFsInFolder: Bool = false
    @Published var history: [SplitJobRecord] = []

    @Published var isWorking: Bool = false
    @Published var status: String = "Ready"
    @Published var progressText: String?
    @Published var progressValue: Double?
    @Published var lastOutputFiles: [URL] = []

    /// Simple validation flag for the Split button.
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
            return true   // validation handled by the splitter based on outline presence
        }
    }

    private let splitter = PDFSplitter()

    func setSource(url: URL) {
        sourceURL = url
        // Default destination mirrors the source folder.
        destinationURL = url.deletingLastPathComponent()
        status = "Ready"
        progressText = nil
        progressValue = nil
        lastOutputFiles = []
    }

    func setDestination(url: URL) {
        destinationURL = url
    }

    func split() {
        guard let src = sourceURL else {
            status = "Select a PDF file first."
            return
        }
        guard let mode = makeSplitMode() else {
            status = "Invalid split settings."
            return
        }

        let dest = destinationURL ?? src.deletingLastPathComponent()
        let sourceFolder = src.deletingLastPathComponent()

        isWorking = true
        status = "Splitting…"
        progressText = nil
        progressValue = nil
        lastOutputFiles = []

        if applyToAllPDFsInFolder {
            splitBatch(inFolder: sourceFolder, destination: dest, mode: mode)
        } else {
            splitSingleFile(source: src, destination: dest, mode: mode) { [weak self] result in
                guard let self else { return }
                self.isWorking = false
                switch result {
                case .success(let splitResult):
                    self.lastOutputFiles = splitResult.outputFiles
                    let count = splitResult.outputFiles.count
                    if count == 0 {
                        self.status = "No output files were produced."
                    } else {
                        let folder = dest.lastPathComponent
                        self.status = "Done. \(count) file(s) written to \(folder)."
                    }
                    let record = SplitJobRecord(
                        date: Date(),
                        sourceDescription: src.lastPathComponent,
                        modeDescription: self.describeMode(),
                        fileCount: 1,
                        outputCount: count,
                        destinationFolder: dest.lastPathComponent,
                        errorSummary: nil
                    )
                    self.history.append(record)
                    self.progressText = nil
                    self.progressValue = nil
                case .failure(let error):
                    self.status = "Split failed: \(error.localizedDescription)"
                    self.progressText = nil
                    self.progressValue = nil
                }
            }
        }
    }

    private func makeSplitMode() -> PDFSplitMode? {
        switch mode {
        case .maxPagesPerFile:
            guard maxPagesPerFile > 0 else { return nil }
            return .maxPagesPerPart(maxPagesPerFile)
        case .numberOfParts:
            guard numberOfParts > 1 else { return nil }
            return .numberOfParts(numberOfParts)
        case .approxSizeMB:
            guard approxSizeMB > 0 else { return nil }
            return .approxTargetSizeMB(approxSizeMB)
        case .explicitBreaks:
            let breaks = parseExplicitBreaks(from: explicitBreaksText)
            guard !breaks.isEmpty else { return nil }
            return .explicitBreaks(breaks)
        case .outlineChapters:
            return .outlineChapters
        }
    }

    private func describeMode() -> String {
        switch mode {
        case .maxPagesPerFile:
            return "max \(maxPagesPerFile) pages"
        case .numberOfParts:
            return "\(numberOfParts) parts"
        case .approxSizeMB:
            return "~\(approxSizeMB) MB"
        case .explicitBreaks:
            return "page breaks: \(explicitBreaksText)"
        case .outlineChapters:
            return "outline chapters"
        }
    }

    private func splitSingleFile(source: URL,
                                 destination: URL,
                                 mode: PDFSplitMode,
                                 completion: @escaping (Result<PDFSplitResult, Error>) -> Void) {
        
        // Repair/Normalize
        var finalSource = source
        do {
            finalSource = try PDFRepairService().repairIfNeeded(inputURL: source)
        } catch {
            print("Split repair failed: \(error)")
        }
        
        let options = PDFSplitOptions(sourceURL: finalSource,
                                      destinationDirectory: destination,
                                      mode: mode)
        splitter.splitAsync(options: options,
                            progress: { [weak self] processed, total in
                                guard let self else { return }
                                self.progressText = "Processed \(processed)/\(total) pages"
                                if total > 0 {
                                    self.progressValue = Double(processed) / Double(total)
                                } else {
                                    self.progressValue = nil
                                }
                            },
                            completion: completion)
    }

    private func splitBatch(inFolder folder: URL,
                            destination: URL,
                            mode: PDFSplitMode) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let fm = FileManager.default
            let urls: [URL]
            do {
                let contents = try fm.contentsOfDirectory(at: folder,
                                                         includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])
                urls = contents.filter { $0.pathExtension.lowercased() == "pdf" }
            } catch {
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.status = "Failed to list folder: \(error.localizedDescription)"
                }
                return
            }

            if urls.isEmpty {
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.status = "No PDF files found in folder."
                }
                return
            }

            var allOutputs: [URL] = []
            var errors: [String] = []

            for (index, fileURL) in urls.enumerated() {
                DispatchQueue.main.async {
                    self.status = "Splitting \(fileURL.lastPathComponent) (\(index + 1)/\(urls.count))…"
                }

                // Repair/Normalize
                var finalSource = fileURL
                do {
                    finalSource = try PDFRepairService().repairIfNeeded(inputURL: fileURL)
                } catch {
                    print("Split batch repair failed: \(error)")
                }

                let options = PDFSplitOptions(sourceURL: finalSource,
                                              destinationDirectory: destination,
                                              mode: mode)
                do {
                    let result = try self.splitter.split(options: options)
                    allOutputs.append(contentsOf: result.outputFiles)
                } catch {
                    errors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                self.isWorking = false
                self.lastOutputFiles = allOutputs
                if !errors.isEmpty {
                    self.status = "Done with errors. Processed \(urls.count) PDFs, created \(allOutputs.count) files."
                } else {
                    self.status = "Done. Processed \(urls.count) PDFs, created \(allOutputs.count) files."
                }
                let errorsSummary: String? = errors.isEmpty ? nil : errors.joined(separator: " | ")
                let record = SplitJobRecord(
                    date: Date(),
                    sourceDescription: folder.lastPathComponent,
                    modeDescription: self.describeMode(),
                    fileCount: urls.count,
                    outputCount: allOutputs.count,
                    destinationFolder: destination.lastPathComponent,
                    errorSummary: errorsSummary
                )
                self.history.append(record)
                self.progressText = nil
                self.progressValue = nil
            }
        }
    }

    private func parseExplicitBreaks(from text: String) -> [Int] {
        let separators = CharacterSet(charactersIn: ",; ")
        let tokens = text.components(separatedBy: separators)
        let values = tokens.compactMap { token -> Int? in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        }
        return values
    }
}
