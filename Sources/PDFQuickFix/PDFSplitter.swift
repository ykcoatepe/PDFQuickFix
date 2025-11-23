import Foundation
import PDFKit

enum PDFSplitMode {
    case maxPagesPerPart(Int)      // e.g. 500 pages per part
    case numberOfParts(Int)        // e.g. split into 10 parts
    case explicitBreaks([Int])     // 1-based page indices where a new part starts (must include 1)
    case approxTargetSizeMB(Double)    // approximate target size in megabytes per part
}

extension PDFSplitter {

    /// Runs splitting on a background queue and calls back on the main queue.
    func splitAsync(options: PDFSplitOptions,
                    progress: ((Int, Int) -> Void)? = nil,
                    completion: @escaping (Result<PDFSplitResult, Error>) -> Void) {

        // Ensure UI-bound progress callbacks execute on the main queue.
        let progressOnMain: ((Int, Int) -> Void)? = progress.map { callback in
            return { processed, total in
                DispatchQueue.main.async {
                    callback(processed, total)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.split(options: options, progress: progressOnMain)
                DispatchQueue.main.async {
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}

struct PDFSplitOptions {
    let sourceURL: URL
    let destinationDirectory: URL
    let mode: PDFSplitMode
}

struct PDFSplitResult {
    let outputFiles: [URL]
}

enum PDFSplitError: Error {
    case cannotOpenSource
    case noPages
    case invalidMode(String)
    case writeFailed(URL)
}

final class PDFSplitter {

    /// Synchronous API; call from a background queue for large documents.
    func split(options: PDFSplitOptions, progress: ((Int, Int) -> Void)? = nil) throws -> PDFSplitResult {
        guard let sourceDoc = PDFDocument(url: options.sourceURL) else {
            throw PDFSplitError.cannotOpenSource
        }
        let pageCount = sourceDoc.pageCount
        guard pageCount > 0 else {
            throw PDFSplitError.noPages
        }

        let effectiveMode = try resolvedMode(for: options.mode,
                                             pageCount: pageCount,
                                             sourceURL: options.sourceURL)
        let ranges = try makeRanges(pageCount: pageCount, mode: effectiveMode)
        let outputURLs = try writeParts(source: sourceDoc,
                                        ranges: ranges,
                                        sourceURL: options.sourceURL,
                                        destinationDirectory: options.destinationDirectory,
                                        progress: progress)
        return PDFSplitResult(outputFiles: outputURLs)
    }

    // MARK: - Range calculation

    private func makeRanges(pageCount: Int, mode: PDFSplitMode) throws -> [Range<Int>] {
        switch mode {
        case .maxPagesPerPart(let maxPages):
            guard maxPages > 0 else {
                throw PDFSplitError.invalidMode("maxPagesPerPart must be > 0")
            }
            var ranges: [Range<Int>] = []
            var start = 0
            while start < pageCount {
                let end = min(start + maxPages, pageCount)
                ranges.append(start..<end)
                start = end
            }
            return ranges

        case .numberOfParts(let parts):
            guard parts > 0 else {
                throw PDFSplitError.invalidMode("numberOfParts must be > 0")
            }
            if parts == 1 {
                return [0..<pageCount]
            }
            let base = pageCount / parts
            let remainder = pageCount % parts

            var ranges: [Range<Int>] = []
            var start = 0
            for i in 0..<parts {
                let extra = (i < remainder) ? 1 : 0
                let length = base + extra
                if length <= 0 { continue }
                let end = min(start + length, pageCount)
                if start < end {
                    ranges.append(start..<end)
                }
                start = end
            }
            if ranges.isEmpty {
                ranges = [0..<pageCount]
            }
            return ranges

        case .explicitBreaks(let breaks):
            // breaks are 1-based page indices where a part starts.
            // e.g. [1, 101, 351] → [0..<100], [100..<350], [350..<pageCount]
            let sorted = Array(Set(breaks)).sorted()
            guard let first = sorted.first, first == 1 else {
                throw PDFSplitError.invalidMode("explicitBreaks must include 1 as the first start page")
            }
            var ranges: [Range<Int>] = []
            var startPage = first
            for i in 1..<sorted.count {
                let nextStart = sorted[i]
                if nextStart <= startPage { continue }
                let startIndex = startPage - 1
                let endIndex = min(nextStart - 1, pageCount)
                if startIndex < endIndex {
                    ranges.append(startIndex..<endIndex)
                }
                startPage = nextStart
            }
            // last range to end of document
            let finalStartIndex = startPage - 1
            if finalStartIndex < pageCount {
                ranges.append(finalStartIndex..<pageCount)
            }
            if ranges.isEmpty {
                ranges = [0..<pageCount]
            }
            return ranges

        case .approxTargetSizeMB:
            // Should be transformed to maxPagesPerPart before reaching here.
            throw PDFSplitError.invalidMode("approxTargetSizeMB must be resolved before range calculation")
        }
    }

    // MARK: - Writing parts

    private func writeParts(source: PDFDocument,
                            ranges: [Range<Int>],
                            sourceURL: URL,
                            destinationDirectory: URL,
                            progress: ((Int, Int) -> Void)? = nil) throws -> [URL] {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let totalParts = ranges.count
        var outputURLs: [URL] = []
        outputURLs.reserveCapacity(totalParts)

        let totalPages = source.pageCount
        var processedPages = 0

        for (index, range) in ranges.enumerated() {
            let partIndex = index + 1
            let startPageNumber = range.lowerBound + 1 // 1-based
            let endPageNumber = range.upperBound       // 1-based

            let partIndexString = String(format: "%02d", partIndex)
            let partCountString = String(format: "%02d", totalParts)
            let startString = String(format: "%04d", startPageNumber)
            let endString = String(format: "%04d", endPageNumber)

            let filename = "\(baseName)_part\(partIndexString)-of\(partCountString)_pages\(startString)-\(endString).pdf"
            let outputURL = destinationDirectory.appendingPathComponent(filename)

            let partDoc = PDFDocument()
            var targetIndex = 0
            for pageIndex in range {
                // Copy pages so the source document remains intact; PDFPage can belong to only one PDFDocument.
                guard let pageCopy = source.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                partDoc.insert(pageCopy, at: targetIndex)
                targetIndex += 1

                processedPages += 1
                progress?(processedPages, totalPages)
            }

            guard partDoc.pageCount > 0 else { continue }

            if !partDoc.write(to: outputURL) {
                throw PDFSplitError.writeFailed(outputURL)
            }
            outputURLs.append(outputURL)
        }

        return outputURLs
    }

    // MARK: - Mode resolution

    private func resolvedMode(for mode: PDFSplitMode,
                               pageCount: Int,
                               sourceURL: URL) throws -> PDFSplitMode {
        switch mode {
        case .approxTargetSizeMB(let targetMB):
            guard targetMB > 0 else {
                throw PDFSplitError.invalidMode("approxTargetSizeMB must be > 0")
            }

            let totalBytes: Int64?
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
                totalBytes = attrs[.size] as? Int64
            } catch {
                totalBytes = nil
            }

            guard let bytes = totalBytes, bytes > 0 else {
                return .maxPagesPerPart(pageCount)
            }

            let totalMB = Double(bytes) / (1024.0 * 1024.0)
            guard totalMB > 0 else {
                return .maxPagesPerPart(pageCount)
            }

            let pagesPerMB = Double(pageCount) / totalMB
            var estimatedPages = Int(pagesPerMB * targetMB)
            if estimatedPages <= 0 {
                estimatedPages = 1
            } else if estimatedPages > pageCount {
                estimatedPages = pageCount
            }

            return .maxPagesPerPart(estimatedPages)

        default:
            return mode
        }
    }
}
