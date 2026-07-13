#if DEBUG
    import AppKit
    import Foundation
    import PDFKit

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
    }
#endif
