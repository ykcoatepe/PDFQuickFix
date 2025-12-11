import Foundation
import os
import PDFCore
import CoreGraphics

public enum PDFRepairOutcome: Error {
    case skippedTooLarge
    case parseFailed(Error)
    case rewriteFailed(Error)
    case validationFailed
    case repaired
    case noChange
}

public struct PDFRepairService {
    private let logger = Logger(subsystem: "com.yordamkocatepe.PDFQuickFixKit", category: "PDFRepairService")
    
    /// Dedicated temp directory for repaired PDFs
    private static let tempSubdirectory = "PDFQuickFix-Repaired"
    
    /// Max age for temp files before automatic cleanup (1 hour)
    private static let maxTempFileAge: TimeInterval = 3600
    
    public init() {
        // Clean up old temp files on init
        Self.cleanupOldTempFiles()
    }
    
    /// Returns the dedicated temp directory for repaired PDFs
    private static var repairedTempDirectory: URL {
        let tempDir = FileManager.default.temporaryDirectory
        let repairDir = tempDir.appendingPathComponent(tempSubdirectory)
        
        // Create if needed
        if !FileManager.default.fileExists(atPath: repairDir.path) {
            try? FileManager.default.createDirectory(at: repairDir, withIntermediateDirectories: true)
        }
        
        return repairDir
    }
    
    /// Clean up temp files older than maxTempFileAge
    public static func cleanupOldTempFiles() {
        let repairDir = repairedTempDirectory
        let cutoff = Date().addingTimeInterval(-maxTempFileAge)
        
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: repairDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        
        for file in files {
            guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modDate = attrs.contentModificationDate else { continue }
            
            if modDate < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
    
    /// Clean up all temp files immediately
    public static func cleanupAllTempFiles() {
        let repairDir = repairedTempDirectory
        try? FileManager.default.removeItem(at: repairDir)
        // Recreate the directory
        try? FileManager.default.createDirectory(at: repairDir, withIntermediateDirectories: true)
    }
    
    /// Generate a temp URL for repaired PDF
    private static func makeTempURL() -> URL {
        return repairedTempDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
    }
    
    public func repairIfNeeded(inputURL: URL) throws -> URL {
        let start = Date()
        var outcome: PDFRepairOutcome = .noChange
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        let maxSizeBytes: Int64 = 50 * 1024 * 1024

        defer {
            let duration = Date().timeIntervalSince(start)
            logOutcome(outcome, fileSize: fileSize, duration: duration, url: inputURL, isManual: false)
        }

        logger.info("PDFRepairService: Checking document at \(inputURL.path)")

        // Skip giant files before loading into memory.
        if fileSize > maxSizeBytes {
            outcome = .skippedTooLarge
            logger.info("PDFRepairService: Document too large (\(fileSize) bytes), skipping normalization.")
            return inputURL
        }
        
        do {
            let data = try Data(contentsOf: inputURL)
            
            // Safety check: Size limit (e.g., 50MB)
            if data.count > maxSizeBytes {
                outcome = .skippedTooLarge
                logger.info("PDFRepairService: Document too large (\(data.count) bytes), skipping normalization.")
                return inputURL
            }
            
            let parser = PDFCoreParser(data: data)
            let document: PDFCoreDocument
            do {
                document = try parser.parseDocument()
            } catch {
                outcome = .parseFailed(error)
                throw error
            }
            
            let normalizedData: Data
            do {
                normalizedData = try PDFCoreWriter.write(document: document)
            } catch {
                outcome = .rewriteFailed(error)
                throw error
            }
            
            let tempURL = Self.makeTempURL()
            try normalizedData.write(to: tempURL, options: .atomic)
            
            // Validate output
            guard let _ = CGPDFDocument(tempURL as CFURL) else {
                outcome = .validationFailed
                logger.error("PDFRepairService: Normalized document validation failed. Reverting to original.")
                try? FileManager.default.removeItem(at: tempURL)
                return inputURL
            }
            
            outcome = .repaired
            logger.info("PDFRepairService: Successfully normalized document")
            return tempURL
        } catch {
            logger.error("PDFRepairService: Failed to normalize, falling back to original. Error: \(error.localizedDescription)")
            // Outcome is already set in do-catch blocks above if specific steps failed
            if case .noChange = outcome {
                 // Fallback if error happened outside specific blocks (e.g. Data read)
                 outcome = .parseFailed(error)
            }
            return inputURL
        }
    }
    
    public func repairForExport(inputURL: URL) throws -> URL {
        let start = Date()
        var outcome: PDFRepairOutcome = .noChange
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        
        defer {
            let duration = Date().timeIntervalSince(start)
            logOutcome(outcome, fileSize: fileSize, duration: duration, url: inputURL, isManual: true)
        }
        
        logger.info("PDFRepairService: Manual repair requested for \(inputURL.path)")
        
        do {
            let data = try Data(contentsOf: inputURL)
            let parser = PDFCoreParser(data: data)
            let document: PDFCoreDocument
            do {
                document = try parser.parseDocument()
            } catch {
                outcome = .parseFailed(error)
                throw error
            }
            
            let normalizedData: Data
            do {
                normalizedData = try PDFCoreWriter.write(document: document)
            } catch {
                outcome = .rewriteFailed(error)
                throw error
            }
            
            let tempURL = Self.makeTempURL()
            try normalizedData.write(to: tempURL, options: .atomic)
            
            // Validate output
            guard let _ = CGPDFDocument(tempURL as CFURL) else {
                outcome = .validationFailed
                logger.error("PDFRepairService: Normalized document validation failed.")
                try? FileManager.default.removeItem(at: tempURL)
                throw PDFRepairOutcome.validationFailed // Or a specific error
            }
            
            outcome = .repaired
            logger.info("PDFRepairService: Successfully normalized document (manual)")
            return tempURL
        } catch {
            logger.error("PDFRepairService: Manual repair failed. Error: \(error.localizedDescription)")
            if case .noChange = outcome {
                 outcome = .parseFailed(error)
            }
            throw error
        }
    }
    
    private func logOutcome(_ outcome: PDFRepairOutcome, fileSize: Int64, duration: TimeInterval, url: URL, isManual: Bool) {
        let outcomeString: String
        switch outcome {
        case .skippedTooLarge: outcomeString = "SkippedTooLarge"
        case .parseFailed(let e): outcomeString = "ParseFailed(\(e))"
        case .rewriteFailed(let e): outcomeString = "RewriteFailed(\(e))"
        case .validationFailed: outcomeString = "ValidationFailed"
        case .repaired: outcomeString = "Repaired"
        case .noChange: outcomeString = "NoChange"
        }
        
        let mode = isManual ? "manual" : "auto"
        logger.info("PDFRepairTelemetry: mode=\(mode) outcome=\(outcomeString) size=\(fileSize) duration=\(duration, format: .fixed(precision: 3))s file=\(url.lastPathComponent)")
    }
}

public struct RepairResult: Codable {
    public enum Mode: String, Codable {
        case cli
    }
    
    public enum Outcome: String, Codable {
        case noChange
        case repaired
        case skippedTooLarge
        case parseFailed
        case validationFailed
        case unsupportedFeature
        case ioError
    }
    
    public var mode: Mode
    public var outcome: Outcome
    public var originalSize: Int
    public var repairedSize: Int?
    public var durationMillis: Int
    public var pageCount: Int?
    public var reason: String?
    public var sourcePath: String
    public var outputPath: String?
    
    public init(mode: Mode,
                outcome: Outcome,
                originalSize: Int,
                repairedSize: Int? = nil,
                durationMillis: Int,
                pageCount: Int? = nil,
                reason: String? = nil,
                sourcePath: String,
                outputPath: String? = nil) {
        self.mode = mode
        self.outcome = outcome
        self.originalSize = originalSize
        self.repairedSize = repairedSize
        self.durationMillis = durationMillis
        self.pageCount = pageCount
        self.reason = reason
        self.sourcePath = sourcePath
        self.outputPath = outputPath
    }
}

extension PDFRepairService {
    public func repairForCLI(inputURL: URL, outputURL: URL?) -> RepairResult {
        return repairForCLI(inputURL: inputURL, outputURL: outputURL, ignoreSizeLimit: false)
    }

    
    public func repairForCLI(inputURL: URL, outputURL: URL?, ignoreSizeLimit: Bool) -> RepairResult {
        let start = Date()
        var outcome: RepairResult.Outcome = .noChange
        var reason: String? = nil
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int) ?? 0
        var repairedSize: Int? = nil
        var pageCount: Int? = nil
        
        let maxSizeBytes: Int = 50 * 1024 * 1024
        
        do {
            if !ignoreSizeLimit && fileSize > maxSizeBytes {
                outcome = .skippedTooLarge
                reason = "File size \(fileSize) exceeds 50MB limit"
                return makeResult()
            }
            
            let data = try Data(contentsOf: inputURL)
            if !ignoreSizeLimit && data.count > maxSizeBytes {
                outcome = .skippedTooLarge
                reason = "File size \(data.count) exceeds 50MB limit"
                return makeResult()
            }
            
            let parser = PDFCoreParser(data: data)
            let document: PDFCoreDocument
            do {
                document = try parser.parseDocument()
                // Assuming PDFCoreDocument doesn't expose pageCount directly yet, or does it? 
                // Previous check of PDFCoreDocument might be needed. 
                // But typically it has trailer/catalog. Let's look up pageCount later if needed.
                // For now, let's just proceed.
            } catch {
                outcome = .parseFailed
                reason = error.localizedDescription
                // Check for unsupported feature error specifically
                if "\(error)".contains("unsupportedFeature") {
                    outcome = .unsupportedFeature
                }
                return makeResult()
            }
            
            let normalizedData: Data
            do {
                normalizedData = try PDFCoreWriter.write(document: document)
            } catch {
                outcome = .parseFailed // Map writer errors to parseFailed or generic failure? Use parseFailed as catch-all or validationFailed?
                // The prompt lists: parseFailed, validationFailed. Writer failure is close to parseFailed or internal logic error.
                // Let's stick to parseFailed or maybe we need a new enum case? 
                // Prompt offered: (noChange, repaired, skippedTooLarge, parseFailed, validationFailed, unsupportedFeature, ioError)
                // "rewriteFailed" isn't in the list. parseFailed is closest.
                reason = "Writer failed: \(error.localizedDescription)"
                return makeResult()
            }
            
            // Validate output
            // We can't easily validate without writing to disk for CGPDFDocument.
            // But for CLI, we might want to skip CGPDF validation if just dry-run?
            // "If outputURL is nil, do a dry-run (parse + validate)"
            // So we DO need to validate.
            
            // Write to memory/temp for validation?
            // CGPDFDocumentProvider can work with CGDataConsumer?
            // Or just write to temp.
            
            let tempDir = FileManager.default.temporaryDirectory
            let tempValidationURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
            try normalizedData.write(to: tempValidationURL)
            defer { try? FileManager.default.removeItem(at: tempValidationURL) }
            
            guard let cgDoc = CGPDFDocument(tempValidationURL as CFURL) else {
                outcome = .validationFailed
                reason = "CGPDFDocument rejected the output"
                return makeResult()
            }
            
            pageCount = cgDoc.numberOfPages
            repairedSize = normalizedData.count
            
            if let outputURL = outputURL {
                try normalizedData.write(to: outputURL, options: .atomic)
                outcome = .repaired
            } else {
                outcome = .repaired // Dry run successful, would be repaired
                // If dry run, "repaired" implies it WOULD BE repaired.
                // Or "noChange" if input was already perfect? 
                // The core always rewrites. So "repaired" is accurate if we rewrite.
            }
            
        } catch {
            outcome = .ioError
            reason = error.localizedDescription
        }
        
        // Helper to capture closure state
        func makeResult() -> RepairResult {
            let duration = Int(Date().timeIntervalSince(start) * 1000)
            return RepairResult(mode: .cli,
                                outcome: outcome,
                                originalSize: fileSize,
                                repairedSize: repairedSize,
                                durationMillis: duration,
                                pageCount: pageCount,
                                reason: reason,
                                sourcePath: inputURL.path,
                                outputPath: outputURL?.path)
        }
        
        return makeResult()
    }
}
