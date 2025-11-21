import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum PDFDocumentSanitizerError: LocalizedError {
    case unableToOpen(URL)
    case pageRenderFailed(page: Int, reason: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unableToOpen(let url):
            return "Belge açılamadı: \(url.lastPathComponent)."
        case .pageRenderFailed(let page, let reason):
            return "PDF içeriği sayfa \(page) sırasında işlenemedi: \(reason)."
        case .cancelled:
            return "İşlem iptal edildi."
        }
    }
}

enum PDFDocumentSanitizer {
    struct Options {
        enum RebuildMode {
            case auto
            case never
            case rasterize
        }

        var rebuildMode: RebuildMode
        var validationPageLimit: Int?
        var sanitizeAnnotations: Bool
        var sanitizeOutline: Bool

        init(rebuildMode: RebuildMode = .auto, validationPageLimit: Int? = nil, sanitizeAnnotations: Bool = true, sanitizeOutline: Bool = true) {
            self.rebuildMode = rebuildMode
            self.validationPageLimit = validationPageLimit
            self.sanitizeAnnotations = sanitizeAnnotations
            self.sanitizeOutline = sanitizeOutline
        }

        static var full: Options { Options() }
        static func quickOpen(limit: Int = 10) -> Options {
            Options(rebuildMode: .never,
                    validationPageLimit: limit,
                    sanitizeAnnotations: false,
                    sanitizeOutline: false)
        }
    }

    struct ValidationOptions {
        var pageLimit: Int?

        init(pageLimit: Int? = nil) {
            self.pageLimit = pageLimit
        }
    }

    final class Job {
        private let lock = NSLock()
        private var _isCancelled = false

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _isCancelled
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            _isCancelled = true
        }
    }

    typealias ProgressHandler = (_ processedPages: Int, _ totalPages: Int) -> Void

    private static let sanitizerQueue = DispatchQueue(label: "com.pdfquickfix.sanitizer", qos: .userInitiated)
    private static let dateFormatter = ISO8601DateFormatter()
    private static let dateFormatterLock = NSLock()

    static func loadDocument(at url: URL,
                             options: Options = .full,
                             progress: ProgressHandler? = nil) throws -> PDFDocument {
        guard let original = PDFDocument(url: url) else {
            throw PDFDocumentSanitizerError.unableToOpen(url)
        }
        return try sanitize(document: original,
                             sourceURL: url,
                             options: options,
                             progress: progress)
    }

    @discardableResult
    static func loadDocumentAsync(at url: URL,
                                  options: Options = .quickOpen(),
                                  progress: ProgressHandler? = nil,
                                  completion: @escaping (Result<PDFDocument, Error>) -> Void) -> Job {
        let job = Job()
        sanitizerQueue.async {
            guard !job.isCancelled else { return }
            do {
                guard let doc = PDFDocument(url: url) else {
                    throw PDFDocumentSanitizerError.unableToOpen(url)
                }
                let sanitized = try sanitize(document: doc,
                                             sourceURL: url,
                                             options: options,
                                             progress: { processed, total in
                                                 guard !job.isCancelled else { return }
                                                 dispatchToMain {
                                                     progress?(processed, total)
                                                 }
                                             },
                                             shouldCancel: { job.isCancelled })
                guard !job.isCancelled else { return }
                dispatchToMain {
                    completion(.success(sanitized))
                }
            } catch {
                guard !job.isCancelled else { return }
                dispatchToMain {
                    completion(.failure(error))
                }
            }
        }
        return job
    }

    @discardableResult
    static func sanitize(document original: PDFDocument,
                         sourceURL: URL? = nil,
                         options: Options = .full,
                         progress: ProgressHandler? = nil,
                         shouldCancel: () -> Bool = { false }) throws -> PDFDocument {
        enforceStructureTreeOff(original)

        let (cleanedAttributes, attributesChanged) = sanitizeAttributes(from: original.documentAttributes)
        original.documentAttributes = cleanedAttributes
        
        let outlineChanged: Bool
        if options.sanitizeOutline {
            outlineChanged = sanitizeOutline(original.outlineRoot)
        } else {
            outlineChanged = false
        }
        
        let annotationsChanged: Bool
        if options.sanitizeAnnotations {
            annotationsChanged = try sanitizeAnnotations(in: original, shouldCancel: shouldCancel)
        } else {
            annotationsChanged = false
        }

        let requiresRebuild: Bool
        switch options.rebuildMode {
        case .rasterize:
            requiresRebuild = true
        case .never:
            requiresRebuild = false
        case .auto:
            requiresRebuild = attributesChanged || outlineChanged || annotationsChanged
        }

        let workingDocument: PDFDocument
        if requiresRebuild, let redrawn = rebuildDocumentByRasterizing(original, shouldCancel: shouldCancel) {
            enforceStructureTreeOff(redrawn)
            redrawn.documentAttributes = cleanedAttributes
            workingDocument = redrawn
        } else if requiresRebuild,
                  let data = original.dataRepresentation(),
                  let rebuilt = PDFDocument(data: data) {
            enforceStructureTreeOff(rebuilt)
            rebuilt.documentAttributes = cleanedAttributes
            _ = sanitizeOutline(rebuilt.outlineRoot)
            _ = try sanitizeAnnotations(in: rebuilt, shouldCancel: shouldCancel)
            workingDocument = rebuilt
        } else {
            workingDocument = original
        }

        if shouldCancel() { throw PDFDocumentSanitizerError.cancelled }

        let validationOptions = ValidationOptions(pageLimit: options.validationPageLimit)
        let validationURL = sourceURL ?? workingDocument.documentURL
        guard let cgDocument = makeCGPDFDocument(for: workingDocument, url: validationURL) else {
            throw PDFDocumentSanitizerError.pageRenderFailed(page: 0, reason: "PDF doğrulama kaynağı oluşturulamadı")
        }
        try validate(cgDocument: cgDocument,
                     options: validationOptions,
                     progress: progress,
                     shouldCancel: shouldCancel)
        return workingDocument
    }

    static func validate(cgDocument: CGPDFDocument,
                         options: ValidationOptions = ValidationOptions(),
                         progress: ProgressHandler? = nil,
                         shouldCancel: () -> Bool = { false }) throws {
        let pageCount = cgDocument.numberOfPages
        guard pageCount > 0 else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let maxDimension: CGFloat = 1024
        let totalPages: Int
        if let limit = options.pageLimit {
            totalPages = min(limit, pageCount)
        } else {
            totalPages = pageCount
        }
        guard totalPages > 0 else { return }

        for index in 1...totalPages { // CGPDFDocument is 1-based
            if shouldCancel() { throw PDFDocumentSanitizerError.cancelled }
            guard let page = cgDocument.page(at: index) else { continue }
            var pageError: Error?
            autoreleasepool {
                let mediaBox = page.getBoxRect(.mediaBox)
                let safeWidth = max(mediaBox.width, 1)
                let safeHeight = max(mediaBox.height, 1)
                let scale = min(maxDimension / safeWidth, maxDimension / safeHeight, 1)
                let width = max(Int(safeWidth * scale), 1)
                let height = max(Int(safeHeight * scale), 1)

                guard let ctx = CGContext(data: nil,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    pageError = PDFDocumentSanitizerError.pageRenderFailed(page: index, reason: "Çizim bağlamı oluşturulamadı")
                    return
                }
                ctx.interpolationQuality = .high
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

                ctx.saveGState()
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: 0, y: mediaBox.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.drawPDFPage(page)
                ctx.restoreGState()
            }
            if let pageError {
                throw pageError
            }
            progress?(index, totalPages)
        }
    }

    private static func sanitizeAttributes(from attributes: [AnyHashable: Any]?) -> ([PDFDocumentAttribute: Any], Bool) {
        guard let attributes else { return ([:], false) }
        var sanitized: [PDFDocumentAttribute: Any] = [:]
        var changed = false

        for (rawKey, value) in attributes {
            guard let key = attributeKey(from: rawKey) else {
                changed = true
                debugLogUnsupportedAttributeKey(rawKey)
                continue
            }
            guard let sanitizedValue = sanitizeValue(value, for: key) else {
                changed = true
                continue
            }
            sanitized[key] = sanitizedValue
            if !valuesEqual(value, sanitizedValue) {
                changed = true
            }
        }
        return (sanitized, changed)
    }

    private static func attributeKey(from rawKey: AnyHashable) -> PDFDocumentAttribute? {
        if let attr = rawKey as? PDFDocumentAttribute { return attr }
        if let stringKey = rawKey as? String {
            return PDFDocumentAttribute(rawValue: stringKey)
        }
        return nil
    }

    private enum AttributeCategory {
        case string
        case stringArray
        case date
    }

    private static let attributeCategories: [PDFDocumentAttribute: AttributeCategory] = [
        PDFDocumentAttribute.titleAttribute: .string,
        PDFDocumentAttribute.authorAttribute: .string,
        PDFDocumentAttribute.subjectAttribute: .string,
        PDFDocumentAttribute.creatorAttribute: .string,
        PDFDocumentAttribute.producerAttribute: .string,
        PDFDocumentAttribute.keywordsAttribute: .stringArray,
        PDFDocumentAttribute.creationDateAttribute: .date,
        PDFDocumentAttribute.modificationDateAttribute: .date
    ]

    private static func sanitizeValue(_ value: Any?, for key: PDFDocumentAttribute) -> Any? {
        guard let value else { return nil }
        switch attributeCategories[key] ?? .string {
        case .string:
            return coerceToString(value)
        case .stringArray:
            if let stringArray = value as? [String] { return stringArray }
            if let array = value as? [Any] {
                let converted = array.compactMap { coerceToString($0) }
                return converted.isEmpty ? nil : converted
            }
            if let string = coerceToString(value) { return [string] }
            return nil
        case .date:
            if let date = value as? Date { return date }
            if let string = value as? String, let parsed = date(from: string) {
                return parsed
            }
            if let string = value as? NSString, let parsed = date(from: string as String) {
                return parsed
            }
            return nil
        }
    }

    private static func sanitizeOutline(_ outline: PDFOutline?) -> Bool {
        guard let outline else { return false }
        var changed = false
        if let label = outline.label, let coerced = coerceToString(label) {
            if label != coerced { changed = true }
            outline.label = coerced
        }
        for index in 0..<outline.numberOfChildren {
            if sanitizeOutline(outline.child(at: index)) {
                changed = true
            }
        }
        return changed
    }

    private static func sanitizeAnnotations(in document: PDFDocument,
                                            shouldCancel: () -> Bool) throws -> Bool {
        var changed = false
        for pageIndex in 0..<document.pageCount {
            if shouldCancel() { throw PDFDocumentSanitizerError.cancelled }
            guard let page = document.page(at: pageIndex) else { continue }
            autoreleasepool {
                for annotation in page.annotations {
                    if let contents = annotation.contents, let sanitized = coerceToString(contents), sanitized != contents {
                        annotation.contents = sanitized
                        changed = true
                    }
                    if let user = annotation.userName, let sanitized = coerceToString(user), sanitized != user {
                        annotation.userName = sanitized
                        changed = true
                    }
                    if let field = annotation.fieldName, let sanitized = coerceToString(field), sanitized != field {
                        annotation.fieldName = sanitized
                        changed = true
                    }
                    if let widget = annotation.widgetStringValue, let sanitized = coerceToString(widget), sanitized != widget {
                        annotation.widgetStringValue = sanitized
                        changed = true
                    }
                    if let defaultValue = annotation.widgetDefaultStringValue,
                       let sanitized = coerceToString(defaultValue), sanitized != defaultValue {
                        annotation.widgetDefaultStringValue = sanitized
                        changed = true
                    }
                }
            }
        }
        return changed
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
            return string(from: date)
        case let url as URL:
            return url.absoluteString
        case nil:
            return nil
        default:
            return String(describing: value ?? "")
        }
    }

    private static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (left as NSString, right as NSString):
            return left == right
        case let (left as NSNumber, right as NSNumber):
            return left == right
        case let (left as NSDate, right as NSDate):
            return left == right
        case let (left as NSArray, right as NSArray):
            return left == right
        default:
            if let left = lhs as? NSObject, let right = rhs as? NSObject {
                return left == right
            }
            return false
        }
    }

    private static func enforceStructureTreeOff(_ document: PDFDocument) {
        let selectors = [
            "setEmitStructureTree:",
            "setShouldEmitStructureTree:",
            "_setEmitStructureTree:",
            "_setShouldEmitStructureTree:",
            "setShouldNotEmitStructureTree:"
        ]
        let argument = "false" as NSString
        for name in selectors {
            let selector = NSSelectorFromString(name)
            guard document.responds(to: selector) else { continue }
            _ = document.perform(selector, with: argument)
        }
    }

    private static func makeCGPDFDocument(for document: PDFDocument, url: URL?) -> CGPDFDocument? {
        if let url,
           let provider = CGDataProvider(url: url as CFURL),
           let cgDocument = CGPDFDocument(provider) {
            return cgDocument
        }
        if let data = document.dataRepresentation(),
           let provider = CGDataProvider(data: data as CFData) {
            return CGPDFDocument(provider)
        }
        return nil
    }

    private static func rebuildDocumentByRasterizing(_ document: PDFDocument,
                                                     shouldCancel: () -> Bool) -> PDFDocument? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            return nil
        }

        for index in 0..<document.pageCount {
            if shouldCancel() { return nil }
            guard let page = document.page(at: index) else { return nil }
            var shouldAbort = false
            autoreleasepool {
                let bounds = page.bounds(for: .mediaBox)
                guard let image = rasterize(page: page, bounds: bounds) else {
                    shouldAbort = true
                    return
                }
                let pageInfo = [kCGPDFContextMediaBox as String: bounds] as CFDictionary
                ctx.beginPDFPage(pageInfo)
                ctx.draw(image, in: bounds)
                ctx.endPDFPage()
            }
            if shouldAbort { return nil }
        }

        ctx.closePDF()
        return PDFDocument(data: data as Data)
    }

    private static func rasterize(page: PDFPage, bounds: CGRect, scale: CGFloat = 2.0) -> CGImage? {
        let width = max(Int(bounds.width * scale), 1)
        let height = max(Int(bounds.height * scale), 1)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private static func dispatchToMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private static func debugLogUnsupportedAttributeKey(_ key: AnyHashable) {
        #if DEBUG
        NSLog("PDFQuickFix: unsupported attribute key dropped: %@", String(describing: key))
        #endif
    }

    private static func string(from date: Date) -> String {
        dateFormatterLock.lock(); defer { dateFormatterLock.unlock() }
        return dateFormatter.string(from: date)
    }

    private static func date(from string: String) -> Date? {
        dateFormatterLock.lock(); defer { dateFormatterLock.unlock() }
        return dateFormatter.date(from: string)
    }
}
