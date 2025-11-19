import Foundation
import AppKit
import PDFKit

enum TestPDFBuilder {
    static func makeSimplePDF(text: String = "Hello", size: CGSize = CGSize(width: 200, height: 200)) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        attributed.draw(in: CGRect(x: 20, y: size.height / 2 - 20, width: size.width - 40, height: 40))
        image.unlockFocus()

        guard let page = PDFPage(image: image) else {
            throw NSError(domain: "TestPDFBuilder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create PDFPage"])
        }
        let document = PDFDocument()
        document.insert(page, at: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        document.write(to: url)
        return url
    }
}

enum TestPDFRenderer {
    static func render(_ page: PDFPage, size: CGSize = CGSize(width: 200, height: 200)) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))

        let bounds = page.bounds(for: .mediaBox)
        let scaleX = size.width / bounds.width
        let scaleY = size.height / bounds.height
        context.saveGState()
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        return context.makeImage()
    }
}

extension CGImage {
    func color(at point: CGPoint) -> NSColor? {
        let x = max(0, min(Int(point.x), width - 1))
        let y = max(0, min(Int(point.y), height - 1))
        guard let data = dataProvider?.data else { return nil }
        guard let bytes: UnsafePointer<UInt8> = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = 4
        let bytesPerRow = self.bytesPerRow
        let offset = y * bytesPerRow + x * bytesPerPixel
        let r = CGFloat(bytes[offset]) / 255.0
        let g = CGFloat(bytes[offset + 1]) / 255.0
        let b = CGFloat(bytes[offset + 2]) / 255.0
        let a = CGFloat(bytes[offset + 3]) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }
}

extension NSColor {
    func isApproximatelyBlack(tolerance: CGFloat = 0.1) -> Bool {
        let converted = usingColorSpace(.sRGB) ?? self
        return converted.redComponent < tolerance && converted.greenComponent < tolerance && converted.blueComponent < tolerance
    }

    func isApproximatelyWhite(tolerance: CGFloat = 0.1) -> Bool {
        let converted = usingColorSpace(.sRGB) ?? self
        return converted.redComponent > (1 - tolerance) && converted.greenComponent > (1 - tolerance) && converted.blueComponent > (1 - tolerance)
    }

    var relativeLuminance: CGFloat {
        let converted = usingColorSpace(.sRGB) ?? self
        return 0.2126 * converted.redComponent + 0.7152 * converted.greenComponent + 0.0722 * converted.blueComponent
    }
}
