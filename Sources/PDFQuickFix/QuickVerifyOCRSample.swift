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
}
