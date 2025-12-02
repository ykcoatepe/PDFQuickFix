import Foundation
import os
import PDFCore
import CoreGraphics

public enum PDFRepairOutcome {
    case skippedTooLarge
    case parseFailed(Error)
    case rewriteFailed(Error)
    case validationFailed
    case repaired
    case noChange
}

public struct PDFRepairService {
    private let logger = Logger(subsystem: "com.yordamkocatepe.PDFQuickFixKit", category: "PDFRepairService")
    
    public init() {}
    
    public func repairIfNeeded(inputURL: URL) throws -> URL {
        let start = Date()
        var outcome: PDFRepairOutcome = .noChange
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        let maxSizeBytes: Int64 = 50 * 1024 * 1024

        defer {
            let duration = Date().timeIntervalSince(start)
            logOutcome(outcome, fileSize: fileSize, duration: duration, url: inputURL)
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
            
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
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
    
    private func logOutcome(_ outcome: PDFRepairOutcome, fileSize: Int64, duration: TimeInterval, url: URL) {
        let outcomeString: String
        switch outcome {
        case .skippedTooLarge: outcomeString = "SkippedTooLarge"
        case .parseFailed(let e): outcomeString = "ParseFailed(\(e))"
        case .rewriteFailed(let e): outcomeString = "RewriteFailed(\(e))"
        case .validationFailed: outcomeString = "ValidationFailed"
        case .repaired: outcomeString = "Repaired"
        case .noChange: outcomeString = "NoChange"
        }
        
        logger.info("PDFRepairTelemetry: outcome=\(outcomeString) size=\(fileSize) duration=\(duration, format: .fixed(precision: 3))s file=\(url.lastPathComponent)")
    }
}
