import CoreGraphics
import Foundation

/// Document data a reader does not show on the page but that travels with the file.
public enum PDFHiddenDataKind: String, CaseIterable, Sendable, Comparable {
    case xmpMetadata
    case embeddedFiles
    case documentJavaScript
    case openAction
    case additionalActions
    case optionalContent
    case pieceInfo
    case pageThumbnail
    case fileAttachmentAnnotation
    case annotationScript
    case xfaForm

    public var label: String {
        switch self {
        case .xmpMetadata: "XMP metadata"
        case .embeddedFiles: "embedded files"
        case .documentJavaScript: "document JavaScript"
        case .openAction: "open action"
        case .additionalActions: "additional actions"
        case .optionalContent: "optional content layers"
        case .pieceInfo: "application private data"
        case .pageThumbnail: "page thumbnails"
        case .fileAttachmentAnnotation: "file attachment annotations"
        case .annotationScript: "annotation scripts"
        case .xfaForm: "XFA form data"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// Reads the structure of serialized PDF bytes, independent of PDFKit's model,
/// so a sanitize result can be checked against what was actually written.
public enum PDFHiddenDataScanner {
    /// Returns nil when the bytes cannot be read as an unlocked PDF.
    public static func scan(data: Data) -> Set<PDFHiddenDataKind>? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else { return nil }
        return scan(cgDocument: document)
    }

    /// Returns nil when the file cannot be read as an unlocked PDF.
    public static func scan(url: URL) -> Set<PDFHiddenDataKind>? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return scan(data: data)
    }

    /// Returns nil for a locked document, one without a catalog, or one whose
    /// nested resources are too deep or numerous to check completely.
    public static func scan(cgDocument document: CGPDFDocument) -> Set<PDFHiddenDataKind>? {
        guard document.isUnlocked, let catalog = document.catalog else { return nil }
        var found: Set<PDFHiddenDataKind> = []

        if has(catalog, "Metadata") { found.insert(.xmpMetadata) }
        if has(catalog, "OpenAction") { found.insert(.openAction) }
        if has(catalog, "AA") { found.insert(.additionalActions) }
        if has(catalog, "OCProperties") { found.insert(.optionalContent) }
        if has(catalog, "PieceInfo") { found.insert(.pieceInfo) }
        if has(catalog, "AF") || has(catalog, "Collection") { found.insert(.embeddedFiles) }
        if let form = dictionary(catalog, "AcroForm"), has(form, "XFA") { found.insert(.xfaForm) }
        if let names = dictionary(catalog, "Names") {
            if has(names, "EmbeddedFiles") { found.insert(.embeddedFiles) }
            if has(names, "JavaScript") { found.insert(.documentJavaScript) }
        }

        var walk = ResourceWalk()
        let pageCount = document.numberOfPages
        if pageCount > 0 {
            for index in 1 ... pageCount {
                guard let page = document.page(at: index)?.dictionary else { continue }
                scan(page: page, into: &found, walk: &walk)
            }
        }
        return walk.exhausted ? nil : found
    }

    private static func scan(page: CGPDFDictionaryRef,
                             into found: inout Set<PDFHiddenDataKind>,
                             walk: inout ResourceWalk)
    {
        if has(page, "Metadata") { found.insert(.xmpMetadata) }
        if has(page, "PieceInfo") { found.insert(.pieceInfo) }
        if has(page, "AA") { found.insert(.additionalActions) }
        if has(page, "Thumb") { found.insert(.pageThumbnail) }
        if has(page, "AF") { found.insert(.embeddedFiles) }

        var annotations: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(page, "Annots", &annotations), let annotations {
            for index in 0 ..< CGPDFArrayGetCount(annotations) {
                var annotation: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annotations, index, &annotation), let annotation else { continue }
                if name(annotation, "Subtype") == "FileAttachment" || has(annotation, "FS") {
                    found.insert(.fileAttachmentAnnotation)
                }
                if has(annotation, "AA") { found.insert(.annotationScript) }
                if let action = dictionary(annotation, "A"),
                   let type = name(action, "S"),
                   scriptActionTypes.contains(type)
                {
                    found.insert(.annotationScript)
                }
            }
        }

        if let resources = dictionary(page, "Resources") {
            scan(resources: resources, depth: 0, into: &found, walk: &walk)
        }
    }

    private static let scriptActionTypes: Set<String> = [
        "JavaScript", "Launch", "ImportData", "SubmitForm", "Rendition", "Movie", "Sound",
    ]

    /// Bounds the nested-resource walk on hostile or very large documents. A
    /// walk that runs out is reported, so an unchecked document never reads as clean.
    private struct ResourceWalk {
        var seen: Set<CGPDFDictionaryRef> = []
        var remaining = 200_000
        var exhausted = false
    }

    private static func scan(resources: CGPDFDictionaryRef,
                             depth: Int,
                             into found: inout Set<PDFHiddenDataKind>,
                             walk: inout ResourceWalk)
    {
        guard depth < 16, walk.remaining > 0 else {
            walk.exhausted = true
            return
        }
        guard walk.seen.insert(resources).inserted, let objects = dictionary(resources, "XObject") else { return }

        var streams: [CGPDFStreamRef] = []
        withUnsafeMutablePointer(to: &streams) { pointer in
            CGPDFDictionaryApplyFunction(objects, { _, object, context in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream {
                    context?.assumingMemoryBound(to: [CGPDFStreamRef].self).pointee.append(stream)
                }
            }, pointer)
        }

        for stream in streams {
            guard walk.remaining > 0 else {
                walk.exhausted = true
                return
            }
            walk.remaining -= 1
            guard let info = CGPDFStreamGetDictionary(stream), walk.seen.insert(info).inserted else { continue }
            if has(info, "Metadata") { found.insert(.xmpMetadata) }
            if has(info, "PieceInfo") { found.insert(.pieceInfo) }
            if let nested = dictionary(info, "Resources") {
                scan(resources: nested, depth: depth + 1, into: &found, walk: &walk)
            }
        }
    }

    private static func has(_ dictionary: CGPDFDictionaryRef, _ key: String) -> Bool {
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(dictionary, key, &object), let object else { return false }
        return CGPDFObjectGetType(object) != .null
    }

    private static func dictionary(_ parent: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var value: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(parent, key, &value) else { return nil }
        return value
    }

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}
