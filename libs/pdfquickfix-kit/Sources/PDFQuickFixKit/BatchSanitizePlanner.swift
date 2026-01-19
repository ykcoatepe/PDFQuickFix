import Foundation

/// Error cases for batch sanitization planning.
public enum BatchPlannerError: LocalizedError {
    case inputDirectoryNotFound(URL)
    case inputNotDirectory(URL)
    case outputNotDirectory(URL)
    case outputInsideInput(input: URL, output: URL)
    case cannotCreateOutput(URL, Error)
    
    public var errorDescription: String? {
        switch self {
        case .inputDirectoryNotFound(let url):
            return "Input directory not found: \(url.path)"
        case .inputNotDirectory(let url):
            return "Input path is not a directory: \(url.path)"
        case .outputNotDirectory(let url):
            return "Output path exists but is not a directory: \(url.path)"
        case .outputInsideInput(let input, let output):
            return "Output directory (\(output.path)) cannot be inside input directory (\(input.path)) when recursive mode is enabled"
        case .cannotCreateOutput(let url, let error):
            return "Cannot create output directory \(url.path): \(error.localizedDescription)"
        }
    }
}

/// Plans batch sanitization by enumerating input PDFs and computing output paths.
public struct BatchSanitizePlanner {
    
    /// A single item in the batch plan.
    public struct Item: Sendable, Equatable {
        /// Source PDF URL
        public let inputURL: URL
        /// Computed output URL
        public let outputURL: URL
        /// Relative path from input directory (for reporting)
        public let relativePath: String
        /// True if output exists and overwrite=false
        public let willSkip: Bool
        
        public init(inputURL: URL, outputURL: URL, relativePath: String, willSkip: Bool) {
            self.inputURL = inputURL
            self.outputURL = outputURL
            self.relativePath = relativePath
            self.willSkip = willSkip
        }
    }
    
    /// Complete batch plan.
    public struct Plan: Sendable {
        public let items: [Item]
        public let inputDirectory: URL
        public let outputDirectory: URL
        public let recursive: Bool
        public let overwrite: Bool
        
        /// Number of items that will be processed (not skipped)
        public var processableCount: Int {
            items.filter { !$0.willSkip }.count
        }
        
        /// Number of items that will be skipped
        public var skippedCount: Int {
            items.filter { $0.willSkip }.count
        }
        
        public init(items: [Item], inputDirectory: URL, outputDirectory: URL,
                    recursive: Bool, overwrite: Bool) {
            self.items = items
            self.inputDirectory = inputDirectory
            self.outputDirectory = outputDirectory
            self.recursive = recursive
            self.overwrite = overwrite
        }
    }
    
    // MARK: - Planning
    
    /// Plans batch sanitization.
    /// - Parameters:
    ///   - inputDir: Directory containing PDFs to process
    ///   - outputDir: Directory where sanitized PDFs will be written
    ///   - recursive: If true, descend into subdirectories
    ///   - overwrite: If true, overwrite existing files; otherwise skip them
    /// - Throws: `BatchPlannerError` if directories are invalid or output is inside input
    /// - Returns: A plan with all items to process
    public static func plan(
        inputDir: URL,
        outputDir: URL,
        recursive: Bool,
        overwrite: Bool
    ) throws -> Plan {
        let fm = FileManager.default
        
        // Resolve symlinks and standardize paths for comparison
        let resolvedInput = inputDir.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedOutput = outputDir.standardizedFileURL.resolvingSymlinksInPath()
        
        // Validate input directory exists and is a directory
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: resolvedInput.path, isDirectory: &isDir) else {
            throw BatchPlannerError.inputDirectoryNotFound(inputDir)
        }
        guard isDir.boolValue else {
            throw BatchPlannerError.inputNotDirectory(inputDir)
        }
        
        // If output exists, it must be a directory
        if fm.fileExists(atPath: resolvedOutput.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw BatchPlannerError.outputNotDirectory(outputDir)
            }
        }
        
        // Guard: Reject output inside input when recursive
        if recursive {
            let inputPath = resolvedInput.path.hasSuffix("/") ? resolvedInput.path : resolvedInput.path + "/"
            let outputPath = resolvedOutput.path
            if outputPath.hasPrefix(inputPath) || outputPath == resolvedInput.path {
                throw BatchPlannerError.outputInsideInput(input: inputDir, output: outputDir)
            }
        }
        
        // Enumerate PDFs
        let items = try enumeratePDFs(
            in: resolvedInput,
            outputDir: resolvedOutput,
            recursive: recursive,
            overwrite: overwrite
        )
        
        return Plan(
            items: items,
            inputDirectory: resolvedInput,
            outputDirectory: resolvedOutput,
            recursive: recursive,
            overwrite: overwrite
        )
    }
    
    // MARK: - Private
    
    private static func enumeratePDFs(
        in inputDir: URL,
        outputDir: URL,
        recursive: Bool,
        overwrite: Bool
    ) throws -> [Item] {
        let fm = FileManager.default
        
        // Use enumerator with safe options
        let options: FileManager.DirectoryEnumerationOptions = [
            .skipsHiddenFiles,
            .skipsPackageDescendants
        ]
        
        // For non-recursive, we'll filter after enumeration
        // But we still want to skip packages and hidden files at all levels
        
        guard let enumerator = fm.enumerator(
            at: inputDir,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
            options: options,
            errorHandler: { _, error in
                // Log but continue on errors
                print("Warning: Error enumerating \(error.localizedDescription)")
                return true
            }
        ) else {
            return []
        }
        
        var items: [Item] = []
        // Standardize input path for consistent prefix matching
        let standardizedInputDir = inputDir.standardizedFileURL.resolvingSymlinksInPath()
        let inputPath = standardizedInputDir.path
        let inputPathPrefix = inputPath.hasSuffix("/") ? inputPath : inputPath + "/"
        
        while let url = enumerator.nextObject() as? URL {
            // Get resource values
            guard let resourceValues = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
            ) else {
                continue
            }
            
            // Skip symlinked directories to avoid loops
            if resourceValues.isSymbolicLink == true {
                if resourceValues.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            
            // Skip directories
            if resourceValues.isDirectory == true {
                // If not recursive, skip subdirectory contents
                if !recursive {
                    enumerator.skipDescendants()
                }
                continue
            }
            
            // Only process PDF files
            guard url.pathExtension.lowercased() == "pdf" else {
                continue
            }
            
            // Compute relative path using standardized URL
            let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let absolutePath = standardizedURL.path
            let relativePath: String
            if absolutePath.hasPrefix(inputPathPrefix) {
                relativePath = String(absolutePath.dropFirst(inputPathPrefix.count))
            } else if absolutePath.hasPrefix(inputPath) {
                // Handle case where input path is the start and there's no trailing slash match
                let remainder = String(absolutePath.dropFirst(inputPath.count))
                relativePath = remainder.hasPrefix("/") ? String(remainder.dropFirst()) : remainder
            } else {
                relativePath = url.lastPathComponent
            }
            
            // Compute output URL preserving directory structure
            let outputURL = outputDir.appendingPathComponent(relativePath)
            
            // Check if output exists
            let outputExists = fm.fileExists(atPath: outputURL.path)
            let willSkip = outputExists && !overwrite
            
            items.append(Item(
                inputURL: url,
                outputURL: outputURL,
                relativePath: relativePath,
                willSkip: willSkip
            ))
        }
        
        // Sort for deterministic ordering
        items.sort { $0.relativePath < $1.relativePath }
        
        return items
    }
}
