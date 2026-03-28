import Foundation
import PDFKit

struct DocumentTextSession {
    enum Scope: Equatable {
        case wholeDocument
        case pageSelection(String)
        case currentPage(index: Int)
        case selection(String)
    }

    private let document: PDFDocument

    init(document: PDFDocument) {
        self.document = document
    }

    init(documentURL: URL) throws {
        let data = try Data(contentsOf: documentURL)
        self.document = PDFDocument(data: data) ?? PDFDocument()
    }

    func extractText(pageSelection: String? = nil) throws -> String {
        try extractText(scope: pageSelection.map { Scope.pageSelection($0) } ?? .wholeDocument)
    }

    func extractText(currentPageIndex: Int) throws -> String {
        try extractText(scope: .currentPage(index: currentPageIndex))
    }

    func extractText(selectionText: String) -> String {
        selectionText
    }

    func extractText(scope: Scope) throws -> String {
        switch scope {
        case .wholeDocument:
            return try extractDocumentText(pageSelection: nil)
        case .pageSelection(let selection):
            return try extractDocumentText(pageSelection: selection)
        case .currentPage(let index):
            return try extractDocumentText(pageSelection: String(index + 1))
        case .selection(let text):
            return text
        }
    }

    static func parsePageSelection(_ selection: String?, pageCount: Int) throws -> [Int] {
        guard let selection = selection?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selection.isEmpty else {
            return Array(0..<pageCount)
        }
        var selected = Set<Int>()
        for token in selection.split(separator: ",") {
            let trimmed = String(token).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 1 {
                let value = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let page = Int(value) else {
                    throw PDFTextExtractorError.invalidPageSelection(String(trimmed))
                }
                try validatePage(page, pageCount: pageCount)
                selected.insert(page - 1)
            } else if parts.count == 2 {
                let startString = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let endString = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let start = Int(startString), let end = Int(endString), start <= end else {
                    throw PDFTextExtractorError.invalidPageSelection(String(trimmed))
                }
                try validatePage(start, pageCount: pageCount)
                try validatePage(end, pageCount: pageCount)
                for page in start...end {
                    selected.insert(page - 1)
                }
            } else {
                throw PDFTextExtractorError.invalidPageSelection(String(trimmed))
            }
        }

        let sorted = selected.sorted()
        if sorted.isEmpty {
            throw PDFTextExtractorError.emptyPageSelection
        }
        return sorted
    }

    private func extractDocumentText(pageSelection: String?) throws -> String {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return "" }
        let pages = try Self.parsePageSelection(pageSelection, pageCount: pageCount)
        var combined = ""
        for index in pages {
            guard let page = document.page(at: index), let text = page.string else { continue }
            combined.append("--- Page \(index + 1) ---\n")
            combined.append(text)
            combined.append("\n\n")
        }
        return combined
    }

    private static func validatePage(_ page: Int, pageCount: Int) throws {
        guard page >= 1 && page <= pageCount else {
            throw PDFTextExtractorError.pageOutOfRange(page, pageCount)
        }
    }
}

enum PDFTextExtractorError: LocalizedError, Equatable {
    case invalidPageSelection(String)
    case pageOutOfRange(Int, Int)
    case emptyPageSelection
    case missingInput

    var errorDescription: String? {
        switch self {
        case .invalidPageSelection(let token):
            return "Invalid page selection: \"\(token)\". Use formats like 1-3, 6."
        case .pageOutOfRange(let page, let total):
            return "Page \(page) is out of range. This document has \(total) pages."
        case .emptyPageSelection:
            return "No pages selected. Enter a page range like 1-3."
        case .missingInput:
            return "Select a document first."
        }
    }
}
