import Foundation
import PDFKit
import PDFQuickFixKit

enum MergeOutlinePolicy: String, CaseIterable, Identifiable {
    case addTopLevelPerSource

    var id: String { rawValue }
}

enum MergeMetadataPolicy: String, CaseIterable, Identifiable {
    case keepFirst
    case keepLast
    case clear

    var id: String { rawValue }
}

struct PDFMergeOptions {
    var insertBlankPageBetweenDocuments: Bool = false
    var skipUnreadableSources: Bool = true
    var deduplicateSources: Bool = false
    var outlinePolicy: MergeOutlinePolicy = .addTopLevelPerSource
    var metadataPolicy: MergeMetadataPolicy = .keepFirst

    static let `default` = PDFMergeOptions()
}

struct PDFMergeResult {
    let outputURL: URL
    let mergedDocumentCount: Int
    let mergedPageCount: Int
    let insertedSeparatorPageCount: Int
    let skippedSources: [URL]
    let warnings: [String]
}

enum PDFMergeError: LocalizedError {
    case noPDFsSelected
    case cannotOpenSource(URL)
    case noReadableSources
    case failedToWriteOutput(URL)

    var errorDescription: String? {
        switch self {
        case .noPDFsSelected:
            return "No PDFs selected."
        case .cannotOpenSource(let url):
            return "Cannot open PDF source: \(url.lastPathComponent)"
        case .noReadableSources:
            return "None of the selected PDFs could be opened."
        case .failedToWriteOutput(let url):
            return "Failed to write merged file to \(url.path)."
        }
    }
}

enum PDFMerge {
    static func merge(urls: [URL], outputURL: URL) throws -> URL {
        let result = try merge(urls: urls, outputURL: outputURL, options: .default)
        return result.outputURL
    }

    static func merge(urls: [URL],
                      outputURL: URL,
                      options: PDFMergeOptions = .default) throws -> PDFMergeResult {
        let inputURLs = options.deduplicateSources ? deduplicated(urls: urls) : urls
        guard !inputURLs.isEmpty else {
            throw PDFMergeError.noPDFsSelected
        }

        let loaded = try loadDocuments(urls: inputURLs, skipUnreadable: options.skipUnreadableSources)
        guard let firstLoaded = loaded.documents.first else {
            throw PDFMergeError.noReadableSources
        }

        let baseDocument = firstLoaded.document
        var outlineEntries: [OutlineEntry] = []
        outlineEntries.reserveCapacity(loaded.documents.count)
        outlineEntries.append(
            OutlineEntry(
                title: firstLoaded.url.deletingPathExtension().lastPathComponent,
                startPageIndex: 0
            )
        )

        var insertedSeparatorPageCount = 0
        for (index, item) in loaded.documents.enumerated() {
            if index == 0 {
                continue
            }

            if options.insertBlankPageBetweenDocuments, let blankPage = makeBlankPageLikeFirstPage(in: baseDocument) {
                baseDocument.insert(blankPage, at: baseDocument.pageCount)
                insertedSeparatorPageCount += 1
            }

            let startPageIndex = baseDocument.pageCount
            outlineEntries.append(
                OutlineEntry(
                    title: item.url.deletingPathExtension().lastPathComponent,
                    startPageIndex: startPageIndex
                )
            )
            for pageIndex in 0..<item.document.pageCount {
                guard let page = item.document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                baseDocument.insert(page, at: baseDocument.pageCount)
            }
        }

        applyMetadata(policy: options.metadataPolicy, to: baseDocument, loadedDocuments: loaded.documents)
        applyOutline(policy: options.outlinePolicy, to: baseDocument, entries: outlineEntries)

        var warnings = loaded.warnings
        if !writeWithRecovery(document: baseDocument, to: outputURL, warnings: &warnings) {
            throw PDFMergeError.failedToWriteOutput(outputURL)
        }
        return PDFMergeResult(
            outputURL: outputURL,
            mergedDocumentCount: loaded.documents.count,
            mergedPageCount: baseDocument.pageCount,
            insertedSeparatorPageCount: insertedSeparatorPageCount,
            skippedSources: loaded.skippedSources,
            warnings: warnings
        )
    }
}

private extension PDFMerge {
    struct LoadedDocument {
        let url: URL
        let document: PDFDocument
    }

    struct LoadDocumentsResult {
        let documents: [LoadedDocument]
        let skippedSources: [URL]
        let warnings: [String]
    }

    struct OutlineEntry {
        let title: String
        let startPageIndex: Int
    }

    static func deduplicated(urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var unique: [URL] = []
        unique.reserveCapacity(urls.count)
        for url in urls {
            let key = url.standardizedFileURL.path
            if seen.insert(key).inserted {
                unique.append(url)
            }
        }
        return unique
    }

    static func loadDocuments(urls: [URL], skipUnreadable: Bool) throws -> LoadDocumentsResult {
        var loaded: [LoadedDocument] = []
        var skipped: [URL] = []
        var warnings: [String] = []

        for url in urls {
            do {
                let doc = try PDFDocumentSanitizer.loadDocument(at: url)
                loaded.append(LoadedDocument(url: url, document: doc))
            } catch {
                if skipUnreadable {
                    skipped.append(url)
                    warnings.append("Skipped unreadable source: \(url.lastPathComponent)")
                    continue
                }
                throw PDFMergeError.cannotOpenSource(url)
            }
        }

        return LoadDocumentsResult(documents: loaded, skippedSources: skipped, warnings: warnings)
    }

    static func makeBlankPageLikeFirstPage(in document: PDFDocument) -> PDFPage? {
        let size = document.page(at: 0)?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return PDFPage(image: image)
    }

    static func applyMetadata(policy: MergeMetadataPolicy,
                              to baseDocument: PDFDocument,
                              loadedDocuments: [LoadedDocument]) {
        switch policy {
        case .keepFirst:
            baseDocument.documentAttributes = sanitizedAttributes(from: loadedDocuments.first?.document.documentAttributes)
        case .keepLast:
            baseDocument.documentAttributes = sanitizedAttributes(from: loadedDocuments.last?.document.documentAttributes)
        case .clear:
            baseDocument.documentAttributes = [:]
        }
    }

    static func applyOutline(policy: MergeOutlinePolicy,
                             to baseDocument: PDFDocument,
                             entries: [OutlineEntry]) {
        switch policy {
        case .addTopLevelPerSource:
            let root = PDFOutline()
            root.label = "Merged Document"

            for entry in entries {
                guard entry.startPageIndex >= 0,
                      entry.startPageIndex < baseDocument.pageCount,
                      let page = baseDocument.page(at: entry.startPageIndex) else { continue }
                let dest = PDFDestination(page: page,
                                          at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY))
                let item = PDFOutline()
                item.label = entry.title
                item.destination = dest
                root.insertChild(item, at: root.numberOfChildren)
            }

            if root.numberOfChildren > 0 {
                baseDocument.outlineRoot = root
            }
        }
    }

    static func writeWithRecovery(document: PDFDocument, to outputURL: URL, warnings: inout [String]) -> Bool {
        if document.write(to: outputURL) {
            return true
        }

        // Retry with sanitized metadata in case attributes block serialization.
        document.documentAttributes = sanitizedAttributes(from: document.documentAttributes)
        if document.write(to: outputURL) {
            warnings.append("Applied metadata sanitization fallback to complete merge write.")
            return true
        }

        // Retry without outline if destinations are problematic for the current PDF.
        document.outlineRoot = nil
        if document.write(to: outputURL) {
            warnings.append("Dropped outline bookmarks to complete merge write.")
            return true
        }

        // Final fallback: write a page-only document.
        let pageOnly = PDFDocument()
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
            pageOnly.insert(page, at: pageOnly.pageCount)
        }
        pageOnly.documentAttributes = [:]
        if pageOnly.write(to: outputURL) {
            warnings.append("Used safe page-only fallback to complete merge write.")
            return true
        }
        return false
    }

    static func sanitizedAttributes(from raw: [AnyHashable: Any]?) -> [PDFDocumentAttribute: Any] {
        guard let raw else { return [:] }
        var sanitized: [PDFDocumentAttribute: Any] = [:]

        let keys: [PDFDocumentAttribute] = [
            .titleAttribute,
            .authorAttribute,
            .subjectAttribute,
            .creatorAttribute,
            .producerAttribute,
            .keywordsAttribute,
            .creationDateAttribute,
            .modificationDateAttribute
        ]

        for key in keys {
            let value = raw[key] ?? raw[key.rawValue]
            guard let value else { continue }
            switch key {
            case .creationDateAttribute, .modificationDateAttribute:
                if let date = value as? Date {
                    sanitized[key] = date
                } else if let string = value as? String,
                          let date = ISO8601DateFormatter().date(from: string) {
                    sanitized[key] = date
                }
            case .keywordsAttribute:
                if let strings = value as? [String] {
                    let cleaned = strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    if !cleaned.isEmpty { sanitized[key] = cleaned }
                } else if let string = value as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { sanitized[key] = [trimmed] }
                }
            default:
                let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { sanitized[key] = text }
            }
        }
        return sanitized
    }
}
