import Foundation
import PDFKit

enum PDFDocumentSanitizer {
    static func sanitize(document: PDFDocument) {
        guard let attributes = document.documentAttributes else { return }
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

            sanitized[key] = coerceValue(value)
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

    private static func coerceValue(_ value: Any?) -> Any? {
        switch value {
        case let date as Date:
            return date
        case let string as String:
            return string
        case let attributed as NSAttributedString:
            return attributed.string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let converted = array.compactMap { coerceToString($0) }
            return converted.isEmpty ? nil : converted
        case nil:
            return nil
        default:
            return coerceToString(value)
        }
    }
}
