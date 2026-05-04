import AppKit
import Foundation
import PDFKit
import PDFQuickFixKit

enum PDFOpsError: LocalizedError {
    case missingDocument
    case invalidInput(String)
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .missingDocument:
            "No PDF document is loaded."
        case let .invalidInput(message):
            message
        case .saveFailed:
            "Failed to save the document."
        }
    }
}

enum WatermarkPosition: String, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case center = "Center"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"

    var id: String {
        rawValue
    }

    func origin(for textSize: CGSize, in bounds: CGRect, margin: CGFloat) -> CGPoint {
        switch self {
        case .topLeft:
            CGPoint(x: bounds.minX + margin,
                    y: bounds.maxY - margin - textSize.height)
        case .topRight:
            CGPoint(x: bounds.maxX - margin - textSize.width,
                    y: bounds.maxY - margin - textSize.height)
        case .center:
            CGPoint(x: bounds.midX - textSize.width / 2,
                    y: bounds.midY - textSize.height / 2)
        case .bottomLeft:
            CGPoint(x: bounds.minX + margin,
                    y: bounds.minY + margin)
        case .bottomRight:
            CGPoint(x: bounds.maxX - margin - textSize.width,
                    y: bounds.minY + margin)
        }
    }
}

enum BatesPlacement: String, CaseIterable, Identifiable {
    case header
    case footer

    var id: String {
        rawValue
    }
}

enum CropTarget: String, CaseIterable, Identifiable {
    case allPages = "All Pages"
    case evenPages = "Even Pages"
    case oddPages = "Odd Pages"

    var id: String {
        rawValue
    }

    func contains(index: Int) -> Bool {
        switch self {
        case .allPages:
            true
        case .evenPages:
            index % 2 == 1
        case .oddPages:
            index % 2 == 0
        }
    }
}

enum PDFOps {
    static let replacementTextAnnotationUserName = "PDFQuickFixReplaceText"

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
        guard let watermarkText = PDFStringNormalizer.normalizedNonEmpty(text, context: "watermark text") else { return }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
        ]

        let rotationValue = Int(rotation)
        let rotationKey = PDFAnnotationKey(rawValue: "Rotation")
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let size = (watermarkText as NSString).size(withAttributes: attributes)
            let origin = position.origin(for: size, in: bounds, margin: margin)
            let annotationBounds = CGRect(origin: origin, size: size)

            let annotation = PDFAnnotation(bounds: annotationBounds,
                                           forType: .freeText,
                                           withProperties: nil)
            annotation.contents = watermarkText
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
        let headerText = PDFStringNormalizer.normalizedNonEmpty(header, context: "header text")
        let footerText = PDFStringNormalizer.normalizedNonEmpty(footer, context: "footer text")
        guard headerText != nil || footerText != nil else { return }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let lineHeight = font.pointSize * 1.4
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let topY = bounds.maxY - margin - font.ascender
            let bottomY = bounds.minY + margin

            if let headerText {
                let headerAnnotation = PDFAnnotation(bounds: CGRect(x: bounds.midX - 200, y: topY, width: 400, height: lineHeight),
                                                     forType: .freeText,
                                                     withProperties: nil)
                headerAnnotation.contents = headerText
                headerAnnotation.font = font
                headerAnnotation.fontColor = NSColor.labelColor.withAlphaComponent(0.85)
                headerAnnotation.color = NSColor.clear
                headerAnnotation.alignment = .center
                page.addAnnotation(headerAnnotation)
            }

            if let footerText {
                let footerAnnotation = PDFAnnotation(bounds: CGRect(x: bounds.midX - 200, y: bottomY, width: 400, height: lineHeight),
                                                     forType: .freeText,
                                                     withProperties: nil)
                footerAnnotation.contents = footerText
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
        let sanitizedPrefix = PDFStringNormalizer.normalize(prefix, context: "Bates prefix") ?? ""
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let lineHeight = font.pointSize * 1.3
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // Build format safely — avoid the "*" width argument which can crash when digits underflow
            let fmt = "%@%0\(max(1, digits))d"
            let number = String(format: fmt, sanitizedPrefix, start + index)

            let y: CGFloat = switch placement {
            case .header:
                bounds.maxY - margin - font.ascender
            case .footer:
                bounds.minY + margin
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
        for index in 0 ..< document.pageCount {
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
        guard let exportDocument = try? privacyPreservingDocumentForExport(document) else {
            return nil
        }
        return exportDocument.dataRepresentation()
    }

    static func metadataCleanedData(document: PDFDocument, sourceURL: URL? = nil) throws -> Data {
        let workingDocument = try privacyPreservingSnapshot(document: document)

        let options = PDFDocumentSanitizer.Options(
            rebuildMode: .alwaysRebuildVectorOrData,
            validationPageLimit: 10,
            sanitizeAnnotations: false,
            sanitizeOutline: false,
            removeOutline: false,
            scrubMetadata: true
        )
        let cleaned = try PDFDocumentSanitizer.sanitize(
            document: workingDocument,
            sourceURL: nil,
            options: options
        )
        cleaned.documentAttributes = [:]

        guard let data = cleaned.dataRepresentation() else {
            throw PDFOpsError.saveFailed
        }
        return data
    }

    static func flattenedData(document: PDFDocument) throws -> Data {
        let flattened = PDFDocument()
        flattened.documentAttributes = document.documentAttributes

        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index),
                  let image = renderedPageImage(page, box: .cropBox),
                  let flattenedPage = PDFPage(image: NSImage(cgImage: image, size: page.bounds(for: .cropBox).size))
            else {
                throw PDFOpsError.invalidInput("Could not flatten page \(index + 1).")
            }
            flattenedPage.rotation = page.rotation
            flattened.insert(flattenedPage, at: flattened.pageCount)
        }
        flattened.outlineRoot = copyOutlineTree(from: document, to: flattened)

        guard let data = flattened.dataRepresentation() else {
            throw PDFOpsError.saveFailed
        }
        return data
    }

    static func containsReplacementTextAnnotations(in document: PDFDocument) -> Bool {
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            if page.annotations.contains(where: { $0.userName == replacementTextAnnotationUserName }) {
                return true
            }
        }
        return false
    }

    static func privacyPreservingDocumentForExport(_ document: PDFDocument) throws -> PDFDocument {
        let detachedSelectionAnnotations = detachSelectionAnnotations(from: document)
        defer { restoreSelectionAnnotations(detachedSelectionAnnotations) }

        if containsReplacementTextAnnotations(in: document) {
            let data = try flattenedData(document: document)
            guard let flattened = PDFDocument(data: data) else {
                throw PDFOpsError.saveFailed
            }
            return flattened
        }

        if document.isEncrypted {
            return try unlockedPageCopy(of: document)
        }

        guard let data = document.dataRepresentation(),
              let snapshot = PDFDocument(data: data)
        else {
            throw PDFOpsError.saveFailed
        }
        return snapshot
    }

    static func privacyPreservingSnapshot(document: PDFDocument) throws -> PDFDocument {
        let exportDocument = try privacyPreservingDocumentForExport(document)
        if exportDocument.isEncrypted {
            return try unlockedPageCopy(of: exportDocument)
        }
        guard let data = exportDocument.dataRepresentation(),
              let snapshot = PDFDocument(data: data)
        else {
            throw PDFOpsError.missingDocument
        }
        return snapshot
    }

    private static func unlockedPageCopy(of document: PDFDocument) throws -> PDFDocument {
        let copy = PDFDocument()
        copy.documentAttributes = document.documentAttributes

        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index),
                  let copiedPage = page.copy() as? PDFPage
            else {
                throw PDFOpsError.missingDocument
            }
            copy.insert(copiedPage, at: copy.pageCount)
        }
        copy.outlineRoot = copyOutlineTree(from: document, to: copy)

        return copy
    }

    private static func detachSelectionAnnotations(from document: PDFDocument) -> [(PDFPage, SelectionAnnotation)] {
        var detached: [(PDFPage, SelectionAnnotation)] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                guard let selectionAnnotation = annotation as? SelectionAnnotation else { continue }
                page.removeAnnotation(selectionAnnotation)
                detached.append((page, selectionAnnotation))
            }
        }
        return detached
    }

    private static func restoreSelectionAnnotations(_ detached: [(PDFPage, SelectionAnnotation)]) {
        for (page, annotation) in detached {
            page.addAnnotation(annotation)
        }
    }

    private static func copyOutlineTree(from source: PDFDocument, to target: PDFDocument) -> PDFOutline? {
        guard let sourceRoot = source.outlineRoot else { return nil }
        let targetRoot = PDFOutline()
        targetRoot.label = sourceRoot.label
        copyOutlineChildren(from: sourceRoot, sourceDocument: source, to: targetRoot, targetDocument: target)
        return targetRoot
    }

    private static func copyOutlineChildren(from sourceParent: PDFOutline,
                                            sourceDocument: PDFDocument,
                                            to targetParent: PDFOutline,
                                            targetDocument: PDFDocument)
    {
        for index in 0 ..< sourceParent.numberOfChildren {
            guard let sourceChild = sourceParent.child(at: index) else { continue }
            let targetChild = PDFOutline()
            targetChild.label = sourceChild.label
            if let destination = copiedDestination(from: sourceChild, sourceDocument: sourceDocument, targetDocument: targetDocument) {
                targetChild.destination = destination
            } else if let action = sourceChild.action?.copy() as? PDFAction {
                targetChild.action = action
            }
            targetParent.insertChild(targetChild, at: targetParent.numberOfChildren)
            copyOutlineChildren(from: sourceChild, sourceDocument: sourceDocument, to: targetChild, targetDocument: targetDocument)
        }
    }

    private static func copiedDestination(from outline: PDFOutline,
                                          sourceDocument: PDFDocument,
                                          targetDocument: PDFDocument) -> PDFDestination?
    {
        let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        guard let sourcePage = destination?.page else { return nil }
        let pageIndex = sourceDocument.index(for: sourcePage)
        guard pageIndex != NSNotFound,
              let targetPage = targetDocument.page(at: pageIndex)
        else {
            return nil
        }
        return PDFDestination(page: targetPage, at: destination?.point ?? .zero)
    }

    static func extractTextForExport(document: PDFDocument) throws -> String {
        guard !containsReplacementTextAnnotations(in: document) else {
            throw PDFOpsError.invalidInput(
                "Text export is blocked after Replace Text or Redact Text because the original text layer may still be extractable. Export a sanitized or flattened PDF copy instead."
            )
        }

        var fullText = ""
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            fullText += "--- Page \(index + 1) ---\n\n"
            fullText += text
            fullText += "\n\n"
        }
        return fullText
    }

    private static func renderedPageImage(_ page: PDFPage, box: PDFDisplayBox) -> CGImage? {
        let bounds = page.bounds(for: box)
        let renderScale: CGFloat = 2
        let width = max(Int((bounds.width * renderScale).rounded(.up)), 1)
        let height = max(Int((bounds.height * renderScale).rounded(.up)), 1)
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return nil
        }

        context.scaleBy(x: renderScale, y: renderScale)
        context.setFillColor(gray: 1, alpha: 1)
        let outputBounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        context.fill(outputBounds)
        context.clip(to: outputBounds)
        context.saveGState()
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        return context.makeImage()
    }
}
