import AppKit
import CoreText
import PDFKit

/// The visible page in an upright, zero-origin output coordinate system.
/// PDFKit's drawing method already applies this crop/rotation transform.
enum PDFPageRenderingError: LocalizedError {
    case incompleteAppearance

    var errorDescription: String? {
        "The page appearance could not be rendered completely. No output was published."
    }
}

struct PDFPageGeometry {
    let pageToDisplay: CGAffineTransform
    let size: CGSize

    init(page: PDFPage, box: PDFDisplayBox = .cropBox) {
        pageToDisplay = page.transform(for: box)
        size = page.bounds(for: box).applying(pageToDisplay).standardized.size
    }

    func displayRect(for pageRect: CGRect) -> CGRect {
        pageRect.applying(pageToDisplay).standardized
    }

    /// A destination's unspecified coordinate is a semantic sentinel, not a number.
    /// Propagate it to each output axis which depends on that source coordinate.
    func displayDestinationPoint(for point: CGPoint) -> CGPoint {
        func coordinate(xWeight: CGFloat, yWeight: CGFloat, offset: CGFloat) -> CGFloat {
            if (xWeight != 0 && point.x == kPDFDestinationUnspecifiedValue)
                || (yWeight != 0 && point.y == kPDFDestinationUnspecifiedValue) {
                return kPDFDestinationUnspecifiedValue
            }
            let x = xWeight == 0 ? 0 : xWeight * point.x
            let y = yWeight == 0 ? 0 : yWeight * point.y
            return x + y + offset
        }
        return CGPoint(x: coordinate(xWeight: pageToDisplay.a, yWeight: pageToDisplay.c, offset: pageToDisplay.tx),
                       y: coordinate(xWeight: pageToDisplay.b, yWeight: pageToDisplay.d, offset: pageToDisplay.ty))
    }

    func draw(_ page: PDFPage, in context: CGContext, target: CGRect, box: PDFDisplayBox = .cropBox) throws {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw PDFPageRenderingError.incompleteAppearance
        }
        let failuresBefore = PDFQFPageDrawingFailureCount()
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: target)
        context.translateBy(x: target.minX, y: target.minY)
        context.scaleBy(x: target.width / size.width, y: target.height / size.height)
        page.draw(with: box, to: context)
        guard PDFQFPageDrawingFailureCount() == failuresBefore else {
            throw PDFPageRenderingError.incompleteAppearance
        }
    }
}

enum PDFTextAppearance {
    /// A single fitted line avoids CTFrame's all-or-nothing line-height rounding.
    static func draw(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, context: CGContext) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(attributed)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard ink.width > 0, ink.height > 0 else { return }
        let scale = min(1, min(rect.width / ink.width, rect.height / ink.height))
        context.saveGState()
        context.clip(to: rect)
        context.textMatrix = .identity
        context.translateBy(x: rect.midX - ink.midX * scale, y: rect.midY - ink.midY * scale)
        context.scaleBy(x: scale, y: scale)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

/// Explicit appearance drawing supplies PDFKit with a complete appearance stream;
/// arbitrary FreeText Rotation keys and alpha-bearing fontColor are not portable.
final class WatermarkAnnotation: PDFAnnotation {
    private let text: String
    private let textFont: NSFont
    private let inkColor: NSColor
    private let angle: CGFloat
    private let lineSize: CGSize

    init(text: String, font: NSFont, color: NSColor, opacity: CGFloat, rotation: CGFloat,
         position: WatermarkPosition, pageBounds: CGRect, margin: CGFloat) {
        self.text = text
        textFont = font
        inkColor = color.withAlphaComponent(max(0, min(1, opacity)))
        angle = rotation * .pi / 180
        let measured = (text as NSString).size(withAttributes: [.font: font])
        lineSize = CGSize(width: measured.width + 4, height: measured.height + 4)
        let rotated = CGRect(origin: .zero, size: lineSize)
            .applying(CGAffineTransform(rotationAngle: angle)).standardized.size
        super.init(bounds: CGRect(origin: position.origin(for: rotated, in: pageBounds, margin: margin), size: rotated),
                   forType: .freeText, withProperties: nil)
        contents = text
        self.font = font
        self.color = .clear
        fontColor = .clear
        border = PDFBorder()
        border?.lineWidth = 0
    }

    required init?(coder: NSCoder) {
        guard let text = coder.decodeObject(forKey: "watermarkText") as? String,
              let font = coder.decodeObject(forKey: "watermarkFont") as? NSFont,
              let color = coder.decodeObject(forKey: "watermarkColor") as? NSColor else { return nil }
        self.text = text
        textFont = font
        inkColor = color
        angle = CGFloat(coder.decodeDouble(forKey: "watermarkAngle"))
        lineSize = coder.decodeSize(forKey: "watermarkSize")
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(text, forKey: "watermarkText")
        coder.encode(textFont, forKey: "watermarkFont")
        coder.encode(inkColor, forKey: "watermarkColor")
        coder.encode(Double(angle), forKey: "watermarkAngle")
        coder.encode(lineSize, forKey: "watermarkSize")
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: angle)
        PDFTextAppearance.draw(text, in: CGRect(x: -lineSize.width / 2, y: -lineSize.height / 2,
                                               width: lineSize.width, height: lineSize.height),
                               font: textFont, color: inkColor, context: context)
        context.restoreGState()
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = WatermarkAnnotation(text: text, font: textFont, color: inkColor, opacity: inkColor.alphaComponent,
                                       rotation: angle * 180 / .pi, position: .center, pageBounds: bounds, margin: 0)
        copy.bounds = bounds
        copy.userName = userName
        return copy
    }
}
