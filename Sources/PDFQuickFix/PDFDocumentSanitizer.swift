import AppKit
import Foundation
import PDFKit

enum PDFDocumentSanitizerError: LocalizedError {
    case unableToOpen(URL)
    case pageRenderFailed(page: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .unableToOpen(let url):
            return "Belge açılamadı: \(url.lastPathComponent)."
        case .pageRenderFailed(let page, let reason):
            return "PDF içeriği sayfa \(page) sırasında işlenemedi: \(reason)."
        }
    }
}

enum PDFDocumentSanitizer {
    /// Loads a PDF from disk, sanitizes informal metadata, and verifies drawing safety.
    static func loadDocument(at url: URL) throws -> PDFDocument {
        guard let original = PDFDocument(url: url) else {
            throw PDFDocumentSanitizerError.unableToOpen(url)
        }
        return try sanitize(document: original)
    }

    /// Returns a sanitized version of the supplied document. The original instance may be mutated but the
    /// returned document should be used going forward (it may be a rebuilt copy).
    @discardableResult
    static func sanitize(document original: PDFDocument) throws -> PDFDocument {
        let cleanedAttributes = sanitizeAttributes(from: original.documentAttributes)
        original.documentAttributes = cleanedAttributes
        sanitizeOutline(original.outlineRoot)
        sanitizeAnnotations(in: original)

        let workingDocument: PDFDocument
        if let data = original.dataRepresentation(),
           let rebuilt = PDFDocument(data: data) {
            rebuilt.documentAttributes = cleanedAttributes
            sanitizeOutline(rebuilt.outlineRoot)
            sanitizeAnnotations(in: rebuilt)
            workingDocument = rebuilt
        } else {
            workingDocument = original
        }

        try validate(document: workingDocument)
        return workingDocument
    }

    private static func sanitizeAttributes(from attributes: [AnyHashable: Any]?) -> [PDFDocumentAttribute: Any] {
        guard let attributes else { return [:] }
        var sanitized: [PDFDocumentAttribute: Any] = [:]
        for (rawKey, value) in attributes {
            let key: PDFDocumentAttribute
            if let attr = rawKey as? PDFDocumentAttribute {
                key = attr
            } else if let stringKey = rawKey as? String {
                key = PDFDocumentAttribute(rawValue: stringKey)
            } else {
                continue
            }
            if let converted = coerceValue(value) {
                sanitized[key] = converted
            }
        }
        return sanitized
    }

    private static func sanitizeOutline(_ outline: PDFOutline?) {
        guard let outline else { return }
        if let label = outline.label, let coerced = coerceToString(label) {
            outline.label = coerced
        }
        for index in 0..<outline.numberOfChildren {
            sanitizeOutline(outline.child(at: index))
        }
    }

    private static func sanitizeAnnotations(in document: PDFDocument) {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                if let contents = annotation.contents, let sanitized = coerceToString(contents) {
                    annotation.contents = sanitized
                }
                if let user = annotation.userName, let sanitized = coerceToString(user) {
                    annotation.userName = sanitized
                }
                if let field = annotation.fieldName, let sanitized = coerceToString(field) {
                    annotation.fieldName = sanitized
                }
                if let widget = annotation.widgetStringValue, let sanitized = coerceToString(widget) {
                    annotation.widgetStringValue = sanitized
                }
                if let defaultValue = annotation.widgetDefaultStringValue, let sanitized = coerceToString(defaultValue) {
                    annotation.widgetDefaultStringValue = sanitized
                }
            }
        }
    }

    private static func coerceToString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let attributed as NSAttributedString:
            return attributed.string
        case let number as NSNumber:
            return number.stringValue
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let url as URL:
            return url.absoluteString
        case nil:
            return nil
        default:
            return String(describing: value ?? "")
        }
    }

    private static func coerceValue(_ value: Any?) -> Any? {
        switch value {
        case let date as Date:
            return date
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let attributed as NSAttributedString:
            return attributed.string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let converted = array.compactMap { coerceToString($0) }
            return converted.isEmpty ? nil : converted
        case let dict as [AnyHashable: Any]:
            let converted = dict.compactMapValues { coerceToString($0) }
            return converted.isEmpty ? nil : converted
        case let url as URL:
            return url.absoluteString
        case nil:
            return nil
        default:
            return coerceToString(value)
        }
    }

    private static func validate(document: PDFDocument) throws {
        guard document.pageCount > 0 else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let maxDimension: CGFloat = 1024

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }

            let mediaBox = page.bounds(for: .mediaBox)
            let safeWidth = max(mediaBox.width, 1)
            let safeHeight = max(mediaBox.height, 1)
            let scale = min(maxDimension / safeWidth, maxDimension / safeHeight, 1)
            let width = max(Int(safeWidth * scale), 1)
            let height = max(Int(safeHeight * scale), 1)

            var nsError: NSError?
            let success = PDFQFPerformBlockCatchingException({
                guard let ctx = CGContext(data: nil,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    return
                }
                ctx.interpolationQuality = .high
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: 0, y: mediaBox.height)
                ctx.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
            }, &nsError)

            if !success {
                let reason = nsError?.localizedDescription ?? "Bilinmeyen içerik hatası"
                throw PDFDocumentSanitizerError.pageRenderFailed(page: index + 1, reason: reason)
            }
        }
    }
}
