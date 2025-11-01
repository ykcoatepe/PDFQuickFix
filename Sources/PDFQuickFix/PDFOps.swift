import Foundation
import PDFKit
import AppKit

enum PDFOpsError: LocalizedError {
    case missingDocument
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .missingDocument:
            return "No PDF document is loaded."
        case .invalidInput(let message):
            return message
        }
    }
}

enum WatermarkPosition: String, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case center = "Center"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"

    var id: String { rawValue }

    func origin(for textSize: CGSize, in bounds: CGRect, margin: CGFloat) -> CGPoint {
        switch self {
        case .topLeft:
            return CGPoint(x: bounds.minX + margin,
                           y: bounds.maxY - margin - textSize.height)
        case .topRight:
            return CGPoint(x: bounds.maxX - margin - textSize.width,
                           y: bounds.maxY - margin - textSize.height)
        case .center:
            return CGPoint(x: bounds.midX - textSize.width / 2,
                           y: bounds.midY - textSize.height / 2)
        case .bottomLeft:
            return CGPoint(x: bounds.minX + margin,
                           y: bounds.minY + margin)
        case .bottomRight:
            return CGPoint(x: bounds.maxX - margin - textSize.width,
                           y: bounds.minY + margin)
        }
    }
}

enum BatesPlacement: String, CaseIterable, Identifiable {
    case header
    case footer

    var id: String { rawValue }
}

enum CropTarget: String, CaseIterable, Identifiable {
    case allPages = "All Pages"
    case evenPages = "Even Pages"
    case oddPages = "Odd Pages"

    var id: String { rawValue }

    func contains(index: Int) -> Bool {
        switch self {
        case .allPages:
            return true
        case .evenPages:
            return index % 2 == 1
        case .oddPages:
            return index % 2 == 0
        }
    }
}

enum PDFOps {
    static func applyWatermark(
        document: PDFDocument,
        text: String,
        fontSize: CGFloat,
        color: NSColor,
        opacity: CGFloat,
        rotation: CGFloat,
        position: WatermarkPosition,
        margin: CGFloat
    ) {
        guard !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]

        let rotationValue = Int(rotation)
        let rotationKey = PDFAnnotationKey(rawValue: "Rotation")
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = position.origin(for: size, in: bounds, margin: margin)
            let annotationBounds = CGRect(origin: origin, size: size)

            let annotation = PDFAnnotation(bounds: annotationBounds,
                                           forType: .freeText,
                                           withProperties: nil)
            annotation.contents = text
            annotation.font = font
            annotation.fontColor = color.withAlphaComponent(opacity)
            annotation.color = NSColor.clear
            annotation.alignment = .center
            annotation.setValue(rotationValue, forAnnotationKey: rotationKey)
            page.addAnnotation(annotation)
        }
    }

    static func applyHeaderFooter(
        document: PDFDocument,
        header: String,
        footer: String,
        margin: CGFloat,
        fontSize: CGFloat
    ) {
        guard !header.isEmpty || !footer.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let lineHeight = font.pointSize * 1.4
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let topY = bounds.maxY - margin - font.ascender
            let bottomY = bounds.minY + margin

            if !header.isEmpty {
                let headerAnnotation = PDFAnnotation(bounds: CGRect(x: bounds.midX - 200, y: topY, width: 400, height: lineHeight),
                                                     forType: .freeText,
                                                     withProperties: nil)
                headerAnnotation.contents = header
                headerAnnotation.font = font
                headerAnnotation.fontColor = NSColor.labelColor.withAlphaComponent(0.85)
                headerAnnotation.color = NSColor.clear
                headerAnnotation.alignment = .center
                page.addAnnotation(headerAnnotation)
            }

            if !footer.isEmpty {
                let footerAnnotation = PDFAnnotation(bounds: CGRect(x: bounds.midX - 200, y: bottomY, width: 400, height: lineHeight),
                                                     forType: .freeText,
                                                     withProperties: nil)
                footerAnnotation.contents = footer
                footerAnnotation.font = font
                footerAnnotation.fontColor = NSColor.labelColor.withAlphaComponent(0.85)
                footerAnnotation.color = NSColor.clear
                footerAnnotation.alignment = .center
                page.addAnnotation(footerAnnotation)
            }
        }
    }

    static func applyBatesNumbers(
        document: PDFDocument,
        prefix: String,
        start: Int,
        digits: Int,
        placement: BatesPlacement,
        margin: CGFloat,
        fontSize: CGFloat
    ) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let lineHeight = font.pointSize * 1.3
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let current = start + index
            let number = prefix + String(format: "%0\(digits)d", current)

            let y: CGFloat
            switch placement {
            case .header:
                y = bounds.maxY - margin - font.ascender
            case .footer:
                y = bounds.minY + margin
            }

            let annotation = PDFAnnotation(bounds: CGRect(x: bounds.maxX - margin - 120, y: y, width: 120, height: lineHeight),
                                           forType: .freeText,
                                           withProperties: nil)
            annotation.contents = number
            annotation.font = font
            annotation.fontColor = NSColor.secondaryLabelColor
            annotation.color = NSColor.clear
            annotation.alignment = .right
            page.addAnnotation(annotation)
        }
    }

    static func crop(
        document: PDFDocument,
        inset: CGFloat,
        target: CropTarget
    ) {
        guard inset > 0 else { return }
        for index in 0..<document.pageCount {
            guard target.contains(index: index),
                  let page = document.page(at: index) else { continue }
            let original = page.bounds(for: .mediaBox)
            let cropped = original.insetBy(dx: inset, dy: inset)
            guard cropped.width > 0, cropped.height > 0 else { continue }
            page.setBounds(cropped, for: .mediaBox)
            page.setBounds(cropped, for: .cropBox)
        }
    }

    static func optimize(document: PDFDocument) -> Data? {
        // dataRepresentation() rebuilds the PDF and strips transient state,
        // which is often enough to compact simple documents.
        document.dataRepresentation()
    }
}
