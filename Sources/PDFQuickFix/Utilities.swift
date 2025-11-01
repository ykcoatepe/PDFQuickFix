import AppKit
import PDFKit
import Vision
import CoreGraphics
import CoreText

extension NSImage {
    var cgImage: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: self.size)
        return self.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}

func visionRectToPixelRect(_ bb: CGRect, imageSize: CGSize) -> CGRect {
    // Vision uses normalized coords with origin at bottom-left
    let x = bb.origin.x * imageSize.width
    let y = (1 - bb.origin.y - bb.size.height) * imageSize.height
    let w = bb.size.width * imageSize.width
    let h = bb.size.height * imageSize.height
    return CGRect(x: x, y: y, width: w, height: h)
}

func pixelsToPoints(_ px: CGFloat, dpi: CGFloat) -> CGFloat {
    return px * 72.0 / dpi
}

func pointsToPixels(_ pt: CGFloat, dpi: CGFloat) -> CGFloat {
    return pt * dpi / 72.0
}

struct RecognizedRun {
    enum Kind {
        case keep(String)
        case replace(String)
        case skip // redacted
    }
    var kind: Kind
    var rectInPixels: CGRect
}

struct PageProcessResult {
    var pageSizePoints: CGSize
    var cgImage: CGImage
    var textRunsInPoints: [RecognizedRun] // rects converted to points; only keep/replace
}
