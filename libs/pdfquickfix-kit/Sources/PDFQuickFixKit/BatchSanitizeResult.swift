import Foundation

/// Report structure for batch sanitization operations.
/// Used by both CLI (JSON output) and App (UI display).
public struct BatchSanitizeReport: Codable, Sendable {
    /// Input directory path
    public let inputDirectory: String
    /// Output directory path
    public let outputDirectory: String
    /// Sanitization profile used
    public let profile: SanitizeProfile
    /// Whether recursive enumeration was enabled
    public let recursive: Bool
    /// Whether this was a dry run (no files written)
    public let dryRun: Bool
    
    /// Count of successfully processed files
    public let processed: Int
    /// Count of skipped files (output existed, overwrite=false)
    public let skipped: Int
    /// Count of failed files
    public let failed: Int
    
    /// Total elapsed time in milliseconds
    public let totalElapsedMs: Int
    
    /// Per-file results
    public let files: [FileResult]
    
    public init(
        inputDirectory: String,
        outputDirectory: String,
        profile: SanitizeProfile,
        recursive: Bool,
        dryRun: Bool,
        processed: Int,
        skipped: Int,
        failed: Int,
        totalElapsedMs: Int,
        files: [FileResult]
    ) {
        self.inputDirectory = inputDirectory
        self.outputDirectory = outputDirectory
        self.profile = profile
        self.recursive = recursive
        self.dryRun = dryRun
        self.processed = processed
        self.skipped = skipped
        self.failed = failed
        self.totalElapsedMs = totalElapsedMs
        self.files = files
    }
    
    /// Per-file result in the batch.
    public struct FileResult: Codable, Sendable {
        /// Relative path from input directory
        public let input: String
        /// Relative path in output directory (always included, even for skipped)
        public let output: String
        /// Processing status
        public let status: Status
        /// Input file size in bytes (nil if not read)
        public let inputBytes: Int?
        /// Output file size in bytes (nil if not written)
        public let outputBytes: Int?
        /// Whether output contains searchable text
        public let searchableText: Bool?
        /// Processing time in milliseconds
        public let elapsedMs: Int?
        /// Error message if failed
        public let error: String?
        
        public init(
            input: String,
            output: String,
            status: Status,
            inputBytes: Int? = nil,
            outputBytes: Int? = nil,
            searchableText: Bool? = nil,
            elapsedMs: Int? = nil,
            error: String? = nil
        ) {
            self.input = input
            self.output = output
            self.status = status
            self.inputBytes = inputBytes
            self.outputBytes = outputBytes
            self.searchableText = searchableText
            self.elapsedMs = elapsedMs
            self.error = error
        }
        
        /// Status of a single file in the batch.
        public enum Status: String, Codable, Sendable {
            case processed
            case skipped
            case failed
        }
    }
}

/// Progress update during batch sanitization.
public struct BatchSanitizeProgress: Sendable {
    /// Current file being processed (1-based)
    public let currentFile: Int
    /// Total number of files in the batch
    public let totalFiles: Int
    /// Relative path of current file
    public let currentPath: String
    /// Whether processing or skipping
    public let isSkipping: Bool
    
    public init(currentFile: Int, totalFiles: Int, currentPath: String, isSkipping: Bool) {
        self.currentFile = currentFile
        self.totalFiles = totalFiles
        self.currentPath = currentPath
        self.isSkipping = isSkipping
    }
    
    /// Progress as a fraction (0.0 to 1.0)
    public var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(currentFile) / Double(totalFiles)
    }
}
