import Foundation

/// Normalizes and guards string values before they get handed to PDFKit/Quartz/Metal.
/// PDFKit frequently assumes values such as labels or annotation contents are NSStrings
/// and will message them with `length`. A stray NSNumber sneaking in from dynamic inputs
/// causes the exact crash we are seeing (`-[__NSCFNumber length]`). Use this helper to
/// coerce values back to Strings and surface debug assertions when the type is wrong.
enum PDFStringNormalizer {
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Returns a String for the supplied value, asserting (in debug) when a non-string slips through.
    static func normalize(_ value: Any?, context: String) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        if let string = value as? NSString {
            return string as String
        }
        if let number = value as? NSNumber {
            assertionFailure(message(for: number, context: context))
            return number.stringValue
        }
        if let date = value as? Date {
            assertionFailure(message(for: date, context: context))
            return isoFormatter.string(from: date)
        }
        assertionFailure(message(for: value, context: context))
        return String(describing: value)
    }

    /// Returns a trimmed, non-empty String or nil if the string becomes empty.
    static func normalizedNonEmpty(_ value: Any?, context: String) -> String? {
        guard let normalized = normalize(value, context: context) else { return nil }
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func message(for value: Any, context: String) -> String {
        "Expected String for \(context); received \(type(of: value)). Automatically stringifying to avoid PDFKit/Metal crashes."
    }
}
