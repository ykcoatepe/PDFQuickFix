import Foundation
import PDFQuickFixKit

/// CLI command: pdfquickfix-cli sanitize-batch <inputDir> <outputDir> [options]
///
/// Options:
///   --profile <privacy-clean|light-clean|keep-editable>
///   --preset <path>           Load profile from JSON preset file
///   --recursive               Process subdirectories
///   --dry-run                 Plan only, don't write files
///   --overwrite               Overwrite existing output files
struct SanitizeBatchCommand {
    
    static func run(args: [String]) throws {
        // Parse arguments
        var inputPath: String?
        var outputPath: String?
        var profile: SanitizeProfile = .privacyClean
        var presetPath: String?
        var recursive = false
        var dryRun = false
        var overwrite = false
        
        var i = 0
        while i < args.count {
            let arg = args[i]
            
            switch arg {
            case "--profile":
                i += 1
                guard i < args.count else {
                    printError("--profile requires a value")
                    exit(1)
                }
                if let p = SanitizeProfile.parse(args[i]) {
                    profile = p
                } else {
                    printError("Unknown profile '\(args[i])'. Available: privacy-clean, light-clean, keep-editable")
                    exit(1)
                }
                
            case "--preset":
                i += 1
                guard i < args.count else {
                    printError("--preset requires a path")
                    exit(1)
                }
                presetPath = args[i]
                
            case "--recursive":
                recursive = true
                
            case "--dry-run":
                dryRun = true
                
            case "--overwrite":
                overwrite = true
                
            case "--help", "-h":
                printUsage()
                exit(0)
                
            default:
                if arg.hasPrefix("-") {
                    printError("Unknown option: \(arg)")
                    printUsage()
                    exit(1)
                }
                // Positional arguments
                if inputPath == nil {
                    inputPath = arg
                } else if outputPath == nil {
                    outputPath = arg
                } else {
                    printError("Unexpected argument: \(arg)")
                    exit(1)
                }
            }
            i += 1
        }
        
        // Validate required arguments
        guard let input = inputPath else {
            printError("Missing required argument: <inputDir>")
            printUsage()
            exit(1)
        }
        guard let output = outputPath else {
            printError("Missing required argument: <outputDir>")
            printUsage()
            exit(1)
        }
        
        // Load preset if specified (overrides --profile)
        if let presetPath = presetPath {
            let presetURL = URL(fileURLWithPath: presetPath)
            guard FileManager.default.fileExists(atPath: presetURL.path) else {
                printError("Preset file not found: \(presetPath)")
                exit(1)
            }
            do {
                let presetData = try Data(contentsOf: presetURL)
                let preset = try JSONDecoder().decode(SanitizePreset.self, from: presetData)
                profile = preset.profile
            } catch let error as DecodingError {
                printError("Invalid preset JSON: \(error.localizedDescription)")
                exit(1)
            } catch {
                printError("Could not read preset file: \(error.localizedDescription)")
                exit(1)
            }
        }
        
        // Create URLs
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)
        
        // Plan the batch
        let plan: BatchSanitizePlanner.Plan
        do {
            plan = try BatchSanitizePlanner.plan(
                inputDir: inputURL,
                outputDir: outputURL,
                recursive: recursive,
                overwrite: overwrite
            )
        } catch {
            printError(error.localizedDescription)
            exit(1)
        }
        
        // Run the batch
        let report = BatchSanitizer.run(
            plan: plan,
            profile: profile,
            dryRun: dryRun,
            progress: { progress in
                // Print progress to stderr so it doesn't interfere with JSON output
                let action = progress.isSkipping ? "Skipping" : "Processing"
                fputs("\r\(action) \(progress.currentFile)/\(progress.totalFiles): \(progress.currentPath)", stderr)
                fflush(stderr)
            }
        )
        
        // Clear progress line
        fputs("\r\u{1B}[K", stderr)
        fflush(stderr)
        
        // Output JSON report
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        if let str = String(data: json, encoding: .utf8) {
            print(str)
        }
        
        // Exit with error code if any failures
        if report.failed > 0 {
            exit(1)
        }
    }
    
    static func printUsage() {
        let usage = """
        Usage: pdfquickfix-cli sanitize-batch <inputDir> <outputDir> [options]
        
        Batch sanitize all PDFs in a directory.
        
        Arguments:
          <inputDir>    Directory containing PDFs to process
          <outputDir>   Directory where sanitized PDFs will be written
        
        Options:
          --profile <name>   Sanitization profile (default: privacy-clean)
                             Values: privacy-clean, light-clean, keep-editable
          --preset <path>    Load profile from JSON preset file (overrides --profile)
          --recursive        Process subdirectories
          --dry-run          Plan only, don't write files
          --overwrite        Overwrite existing output files (default: skip)
          --help, -h         Show this help message
        
        Output:
          JSON report is written to stdout.
          Progress is written to stderr.
        
        Example:
          pdfquickfix-cli sanitize-batch ~/Documents/PDFs ~/Documents/Sanitized --profile light-clean --recursive
        """
        print(usage)
    }
    
    private static func printError(_ message: String) {
        fputs("Error: \(message)\n", stderr)
    }
}
