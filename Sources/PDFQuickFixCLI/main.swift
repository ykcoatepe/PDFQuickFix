import Foundation
import CoreGraphics
import PDFCore
import PDFQuickFixKit

// MARK: - Helper Types

enum CLIError: Error {
    case invalidArguments
    case fileNotFound(String)
    case commandFailed(String)
}

struct InspectResult: Codable {
    let file: String
    let size: Int
    let pageCount: Int
    let xrefType: String
    let hasObjStm: Bool
    let revisions: Int
    let encrypted: Bool
}

// MARK: - App

@main
struct CLI {
    static func main() {
        let args = ProcessInfo.processInfo.arguments
        
        guard args.count > 1 else {
            printUsage()
            exit(1)
        }
        
        let command = args[1]
        
        do {
            switch command {
            case "inspect":
                try runInspect(args: Array(args.dropFirst(2)))
                
            case "repair":
                try runRepair(args: Array(args.dropFirst(2)))
                
            default:
                print("Unknown command: \(command)")
                printUsage()
                exit(1)
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }
    
    static func printUsage() {
        print("""
        Usage: pdfquickfix-cli <command> [options]
        
        Commands:
          inspect <input.pdf>
          repair <input.pdf> <output.pdf> [--no-size-limit]
        """)
    }
    
    // MARK: - Inspect
    
    static func runInspect(args: [String]) throws {
        guard let inputPath = args.first else {
            throw CLIError.invalidArguments
        }
        
        let inputURL = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.fileNotFound(inputPath)
        }
        
        let data = try Data(contentsOf: inputURL)
        
        // Parse with PDFCore to validate structure
        let parser = PDFCoreParser(data: data)
        _ = try parser.parseDocument()
        
        // Use CGPDFDocument for reliable metadata extraction
        var pageCount = 0
        var isEncrypted = false
        if let cgDoc = CGPDFDocument(inputURL as CFURL) {
            pageCount = cgDoc.numberOfPages
            isEncrypted = cgDoc.isEncrypted
        }
        
        // Note: PDFCore doesn't yet expose xrefType, hasObjStm, or revision count.
        // Rather than returning misleading placeholders, we report "unknown".
        let result = InspectResult(
            file: inputURL.lastPathComponent,
            size: data.count,
            pageCount: pageCount,
            xrefType: "unknown",  // PDFCore doesn't expose this
            hasObjStm: false,     // PDFCore doesn't expose this reliably
            revisions: 0,         // 0 = unknown (PDFCore doesn't track revision count)
            encrypted: isEncrypted
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(result)
        if let str = String(data: json, encoding: .utf8) {
            print(str)
        }
    }
    
    // MARK: - Repair
    
    static func runRepair(args: [String]) throws {
        guard args.count >= 2 else {
            throw CLIError.invalidArguments
        }
        
        let inputPath = args[0]
        let outputPath = args[1]
        let ignoreSizeLimit = args.contains("--no-size-limit")
        
        let inputURL = URL(fileURLWithPath: inputPath)
        let outputURL = URL(fileURLWithPath: outputPath)
        
        let service = PDFRepairService()
        let result = service.repairForCLI(inputURL: inputURL, outputURL: outputURL, ignoreSizeLimit: ignoreSizeLimit)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(result)
        if let str = String(data: json, encoding: .utf8) {
            print(str)
        }
    }
}
