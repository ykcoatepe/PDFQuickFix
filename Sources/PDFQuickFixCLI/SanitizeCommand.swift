import Foundation
import PDFCore
import PDFQuickFixKit
import PDFKit

struct SanitizeCommand {
    struct Result: Codable {
        let profile: String
        let inputBytes: Int
        let outputBytes: Int
        let pageCount: Int
        let searchableText: Bool
        let output: String
    }
    
    static func run(args: [String]) throws {
        guard args.count >= 2 else {
            throw CLIError.invalidArguments
        }
        
        // Parse arguments
        var inputPath: String?
        var outputPath: String?
        var profile: SanitizeProfile = .privacyClean
        
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--profile" {
                i += 1
                if i < args.count {
                    if let p = SanitizeProfile(rawValue: args[i]) {
                        profile = p
                    } else {
                        print("Error: Unknown profile '\(args[i])'. Available: privacyClean, lightClean, keepEditable")
                        exit(1)
                    }
                }
            } else if inputPath == nil {
                inputPath = arg
            } else if outputPath == nil {
                outputPath = arg
            }
            i += 1
        }
        
        guard let input = inputPath, let output = outputPath else {
            throw CLIError.invalidArguments
        }
        
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)
        
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw CLIError.fileNotFound(input)
        }
        
        let inputData = try Data(contentsOf: inputURL)
        guard let doc = PDFDocument(data: inputData) else {
            throw CLIError.commandFailed("Could not load PDF")
        }
        
        let options = PDFDocumentSanitizer.Options.from(profile: profile)
        
        // Perform Sanitize
        // We use the synchronous core method from Kit
        let sanitized = try PDFDocumentSanitizer.sanitize(document: doc,
                                                          sourceURL: inputURL,
                                                          options: options)
        
        guard sanitized.write(to: outputURL) else {
            throw CLIError.commandFailed("Failed to write output to \(output)")
        }
        
        // Gather stats for JSON output
        let outputData = try Data(contentsOf: outputURL)
        let pageCount = sanitized.pageCount
        
        // Check searchability roughly
        // If rasterized (privacyClean), text should be empty.
        // If lightClean, text should be present.
        let searchable = (sanitized.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) > 0
        
        let result = Result(profile: profile.rawValue,
                            inputBytes: inputData.count,
                            outputBytes: outputData.count,
                            pageCount: pageCount,
                            searchableText: searchable,
                            output: outputURL.lastPathComponent)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try encoder.encode(result)
        if let str = String(data: json, encoding: .utf8) {
            print(str)
        }
    }
}
