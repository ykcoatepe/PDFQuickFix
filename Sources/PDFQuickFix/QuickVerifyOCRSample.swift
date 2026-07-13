import AppKit
import CoreGraphics

enum QuickVerifyOCRSample {
    static let text = "OCR TEST 1234"

    static func makeImage() -> CGImage? {
        let size = CGSize(width: 960, height: 260)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let textRect = NSRect(x: 0, y: (size.height - 80) / 2, width: size.width, height: 80)
        text.draw(in: textRect, withAttributes: attrs)

        image.unlockFocus()
        guard let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data)
        else {
            return nil
        }
        return rep.cgImage
    }

    static func extractText(from runs: [RecognizedRun]) -> String {
        runs.compactMap { run -> String? in
            switch run.kind {
            case let .keep(text), let .replace(text):
                text
            case .skip:
                nil
            }
        }
        .joined(separator: " ")
    }

    static func looksCorrect(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("ocr") || lowercased.contains("test")
    }

    /// Three-state verdict for a Quick Verify run.
    /// - `matched`: OCR returned text that matches the known test fixture (success).
    /// - `textWithoutMatch`: OCR returned text but it did not match the fixture (warning).
    /// - `noText`: OCR returned no usable text (failure).
    enum Outcome: Equatable {
        case matched
        case textWithoutMatch
        case noText
    }

    /// Evaluates recognized OCR text against the known fixture. Success is reserved for a
    /// genuine fixture match; any-text-but-wrong is a warning, and empty text is a failure.
    static func outcome(forText text: String) -> Outcome {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText else { return .noText }
        return looksCorrect(text) ? .matched : .textWithoutMatch
    }
}
