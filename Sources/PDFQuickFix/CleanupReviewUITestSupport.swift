#if DEBUG
    import AppKit
    import Foundation
    import PDFKit
    import PDFQuickFixKit

    enum CleanupReviewUITestSupport {
        static func requestedMode(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppMode? {
            guard let flagIndex = arguments.firstIndex(of: "--ui-test-cleanup-review"),
                  arguments.indices.contains(flagIndex + 1)
            else {
                return nil
            }
            switch arguments[flagIndex + 1].lowercased() {
            case "reader":
                return .reader
            case "studio":
                return .studio
            default:
                return nil
            }
        }

        static func batchEvidenceRequested(
            arguments: [String] = ProcessInfo.processInfo.arguments
        ) -> Bool {
            arguments.contains("--ui-test-batch-evidence")
        }

        static func makeFixturePDF() throws -> URL {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 640))
            textView.string = "PDFQuickFix cleanup review UI test fixture"
            guard let document = PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)) else {
                throw CocoaError(.fileWriteUnknown)
            }
            document.documentAttributes = [
                PDFDocumentAttribute.authorAttribute: "UI Test Author",
                PDFDocumentAttribute.titleAttribute: "Cleanup Review Fixture",
            ]
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cleanup-review-ui-\(UUID().uuidString)")
                .appendingPathExtension("pdf")
            guard document.write(to: url) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return url
        }

        @MainActor
        static func makeBatchEvidenceViewModel() throws -> BatchSanitizeViewModel {
            let sourceURL = try makeFixturePDF()
            let outputDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("batch-evidence-ui-output-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            let outputURL = outputDirectory.appendingPathComponent("cleanup-review-ui.pdf")
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)

            let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let evidence = try CleanupEvidenceGenerator.generate(
                sourceURL: sourceURL,
                outputURL: outputURL,
                operationKind: .sanitize,
                sanitizeProfile: SanitizeProfile.lightClean.rawValue,
                verdict: .passed,
                generatedAt: generatedAt
            )
            let manifest = BatchCleanupEvidenceManifest(
                generatedAt: generatedAt,
                sanitizeProfile: SanitizeProfile.lightClean.rawValue,
                recursive: false,
                verdict: .passed,
                files: [
                    .init(
                        id: "ui-test-batch-evidence",
                        fileName: sourceURL.lastPathComponent,
                        status: .processed,
                        verdict: .passed,
                        reason: nil,
                        evidence: evidence
                    ),
                ]
            )
            let report = BatchSanitizeReport(
                inputDirectory: sourceURL.deletingLastPathComponent().path,
                outputDirectory: outputDirectory.path,
                profile: .lightClean,
                recursive: false,
                dryRun: false,
                processed: 1,
                skipped: 0,
                failed: 0,
                totalElapsedMs: 25,
                files: [
                    .init(
                        input: sourceURL.lastPathComponent,
                        output: outputURL.lastPathComponent,
                        status: .processed,
                        inputBytes: evidence.source.byteCount,
                        outputBytes: evidence.output.byteCount,
                        searchableText: true,
                        elapsedMs: 25
                    ),
                ]
            )

            let viewModel = BatchSanitizeViewModel()
            viewModel.inputFolderURL = sourceURL.deletingLastPathComponent()
            viewModel.outputFolderURL = outputDirectory
            viewModel.selectedProfile = .lightClean
            viewModel.isRecursive = false
            viewModel.report = report
            viewModel.evidenceManifest = manifest
            return viewModel
        }
    }
#endif
