import Foundation
import PDFKit

enum PDFDocumentSanitizer {
    static func sanitize(document: PDFDocument) {
        guard let attributes = document.documentAttributes as? [PDFDocumentAttribute: Any] else { return }
        var sanitized: [PDFDocumentAttribute: Any] = [:]

        for (key, value) in attributes {
            switch key {
            case PDFDocumentAttribute.titleAttribute,
                 PDFDocumentAttribute.authorAttribute,
                 PDFDocumentAttribute.creatorAttribute,
                 PDFDocumentAttribute.producerAttribute,
                 PDFDocumentAttribute.subjectAttribute:
                sanitized[key] = coerceToString(value)
            case PDFDocumentAttribute.keywordsAttribute:
                sanitized[key] = coerceToStringArray(value)
            case PDFDocumentAttribute.creationDateAttribute,
                 PDFDocumentAttribute.modificationDateAttribute:
                sanitized[key] = value as? Date
            default:
                sanitized[key] = value
            }
        }

        document.documentAttributes = sanitized.compactMapValues { $0 }
    }

    private static func coerceToString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        case let number as NSNumber:
            return number.stringValue
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case nil:
            return nil
        default:
            return String(describing: value ?? "")
        }
    }

    private static func coerceToStringArray(_ value: Any?) -> [String]? {
        switch value {
        case let strings as [String]:
            return strings
        case let anyArray as [Any]:
            let converted = anyArray.compactMap { coerceToString($0) }
            return converted.isEmpty ? nil : converted
        case let string as String:
            return [string]
        default:
            if let single = coerceToString(value) {
                return [single]
            }
            return nil
        }
    }
}
