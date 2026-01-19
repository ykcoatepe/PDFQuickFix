import Foundation
import PDFKit
import CoreFoundation

/// Shared batch sanitization runner used by both CLI and App.
/// Handles the actual processing while CLI/App handle argument parsing and UI.
public enum BatchSanitizer {
    
    public typealias ProgressHandler = (BatchSanitizeProgress) -> Void
    public typealias CancellationChecker = () -> Bool
    
    /// Runs batch sanitization on a planned set of files.
    /// - Parameters:
    ///   - plan: The batch plan from `BatchSanitizePlanner`
    ///   - profile: Sanitization profile to apply
    ///   - dryRun: If true, don't actually write files
    ///   - progress: Optional progress callback
    ///   - shouldCancel: Optional cancellation checker
    /// - Returns: Complete report of the batch operation
    public static func run(
        plan: BatchSanitizePlanner.Plan,
        profile: SanitizeProfile,
        dryRun: Bool,
        progress: ProgressHandler? = nil,
        shouldCancel: CancellationChecker? = nil
    ) -> BatchSanitizeReport {
        let startTime = CFAbsoluteTimeGetCurrent()
        let fm = FileManager.default
        let options = PDFDocumentSanitizer.Options.from(profile: profile)
        
        var fileResults: [BatchSanitizeReport.FileResult] = []
        var processedCount = 0
        var skippedCount = 0
        var failedCount = 0
        
        for (index, item) in plan.items.enumerated() {
            // Cancellation check between files
            if let shouldCancel = shouldCancel, shouldCancel() {
                break
            }
            
            // Report progress
            progress?(BatchSanitizeProgress(
                currentFile: index + 1,
                totalFiles: plan.items.count,
                currentPath: item.relativePath,
                isSkipping: item.willSkip
            ))
            
            // Handle skipped files
            if item.willSkip {
                skippedCount += 1
                fileResults.append(BatchSanitizeReport.FileResult(
                    input: item.relativePath,
                    output: item.relativePath,
                    status: .skipped
                ))
                continue
            }
            
            // Process file
            let fileStart = CFAbsoluteTimeGetCurrent()
            
            do {
                // Read input
                let inputData = try Data(contentsOf: item.inputURL)
                let inputBytes = inputData.count
                
                guard let document = PDFDocument(data: inputData) else {
                    throw BatchSanitizerError.couldNotLoadPDF(item.inputURL)
                }
                
                // Sanitize
                let sanitized = try PDFDocumentSanitizer.sanitize(
                    document: document,
                    sourceURL: item.inputURL,
                    options: options
                )
                
                // Determine searchable text status
                let searchableText = determineSearchableText(
                    document: sanitized,
                    profile: profile
                )
                
                // Write output (unless dry run)
                var outputBytes: Int?
                if !dryRun {
                    // Ensure parent directory exists
                    let parentDir = item.outputURL.deletingLastPathComponent()
                    try fm.createDirectory(
                        at: parentDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                    
                    // Remove existing file if overwrite
                    if fm.fileExists(atPath: item.outputURL.path) {
                        try fm.removeItem(at: item.outputURL)
                    }
                    
                    // Write sanitized PDF
                    guard sanitized.write(to: item.outputURL) else {
                        throw BatchSanitizerError.writeFailed(item.outputURL)
                    }
                    
                    // Get output size
                    let outputData = try Data(contentsOf: item.outputURL)
                    outputBytes = outputData.count
                }
                
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - fileStart) * 1000)
                
                processedCount += 1
                fileResults.append(BatchSanitizeReport.FileResult(
                    input: item.relativePath,
                    output: item.relativePath,
                    status: .processed,
                    inputBytes: inputBytes,
                    outputBytes: outputBytes,
                    searchableText: searchableText,
                    elapsedMs: elapsedMs
                ))
                
            } catch {
                let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - fileStart) * 1000)
                
                failedCount += 1
                fileResults.append(BatchSanitizeReport.FileResult(
                    input: item.relativePath,
                    output: item.relativePath,
                    status: .failed,
                    elapsedMs: elapsedMs,
                    error: error.localizedDescription
                ))
            }
        }
        
        let totalElapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        
        return BatchSanitizeReport(
            inputDirectory: plan.inputDirectory.path,
            outputDirectory: plan.outputDirectory.path,
            profile: profile,
            recursive: plan.recursive,
            dryRun: dryRun,
            processed: processedCount,
            skipped: skippedCount,
            failed: failedCount,
            totalElapsedMs: totalElapsedMs,
            files: fileResults
        )
    }
    
    // MARK: - Private
    
    /// Determines if the output document contains searchable text.
    /// Optimized: privacyClean is always false (rasterized).
    /// For other profiles, checks first N pages for non-empty string content.
    private static func determineSearchableText(
        document: PDFDocument,
        profile: SanitizeProfile,
        pagesToCheck: Int = 3
    ) -> Bool {
        // privacyClean rasterizes everything, so no searchable text
        if profile == .privacyClean {
            return false
        }
        
        // Check first N pages for any text content
        let pageCount = min(document.pageCount, pagesToCheck)
        for i in 0..<pageCount {
            if let page = document.page(at: i),
               let text = page.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        
        return false
    }
}

/// Errors specific to batch sanitization execution.
public enum BatchSanitizerError: LocalizedError {
    case couldNotLoadPDF(URL)
    case writeFailed(URL)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .couldNotLoadPDF(let url):
            return "Could not load PDF: \(url.lastPathComponent)"
        case .writeFailed(let url):
            return "Failed to write: \(url.lastPathComponent)"
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
