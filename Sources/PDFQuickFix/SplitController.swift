import Foundation
import Combine

enum SplitUIMode: Int, CaseIterable {
    case maxPagesPerFile
    case numberOfParts
    case approxSizeMB        // approximate MB target per part
    case explicitBreaks      // comma-separated start pages

    var title: String {
        switch self {
        case .maxPagesPerFile: return "By max pages"
        case .numberOfParts:   return "By number of parts"
        case .approxSizeMB:    return "By size"
        case .explicitBreaks:  return "By page breaks"
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
        let dest = destinationURL ?? src.deletingLastPathComponent()

        let mode: PDFSplitMode
        switch self.mode {
        case .maxPagesPerFile:
            mode = .maxPagesPerPart(maxPagesPerFile)
        case .numberOfParts:
            mode = .numberOfParts(numberOfParts)
        case .approxSizeMB:
            mode = .approxTargetSizeMB(approxSizeMB)
        case .explicitBreaks:
            let breaks = parseExplicitBreaks(from: explicitBreaksText)
            if breaks.isEmpty {
                status = "Invalid page breaks. Enter comma-separated page numbers (e.g. 1, 501, 1001)."
                return
            }
            mode = .explicitBreaks(breaks)
        }

        let options = PDFSplitOptions(sourceURL: src,
                                      destinationDirectory: dest,
                                      mode: mode)

        isWorking = true
        status = "Splitting…"
        progressText = nil
        progressValue = nil
        lastOutputFiles = []

        splitter.splitAsync(options: options,
                            progress: { [weak self] processed, total in
                                guard let self else { return }
                                guard total > 0 else { return }
                                self.progressValue = Double(processed) / Double(total)
                                self.progressText = "Processed \(processed)/\(total) pages"
                            }) { [weak self] result in
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
                self.progressText = nil
                self.progressValue = nil
            case .failure(let error):
                self.status = "Split failed: \(error.localizedDescription)"
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
