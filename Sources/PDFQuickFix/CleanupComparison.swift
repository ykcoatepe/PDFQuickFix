import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

enum CleanupPageClassification: String, Equatable, Sendable {
    case visualChanged
    case textLayerChanged
    case unchanged
}

struct CleanupPageComparison: Equatable, Sendable {
    let pageNumber: Int
    let sourceTextFingerprint: String?
    let outputTextFingerprint: String?
    let textCharacterCountDelta: Int
    let visualDifferenceRatio: Double
    let classification: CleanupPageClassification
}

struct CleanupComparisonResult: Equatable, Sendable {
    let sourcePageCount: Int
    let outputPageCount: Int
    let pages: [CleanupPageComparison]
    let metadataFieldsRemoved: [String]
    let metadataFieldsRemaining: [String]

    var changedPages: [Int] {
        pages.compactMap { page in
            page.classification == .unchanged ? nil : page.pageNumber
        }
    }

    var evidenceSummary: CleanupComparisonSummary {
        let comparedPageCount = pages.count
        let changedPageCount = changedPages.count
        return CleanupComparisonSummary(
            comparedPageCount: comparedPageCount,
            matchingPageCount: comparedPageCount - changedPageCount,
            changedPageCount: changedPageCount,
            maximumDifferenceRatio: pages.map(\.visualDifferenceRatio).max()
        )
    }
}

enum CleanupComparisonError: Error, Equatable {
    case cancelled
    case couldNotRenderPage(Int)
}

/// Produces a privacy-preserving, cleanup-focused summary of two PDF documents.
///
/// Pages are processed serially. Only fixed-size render buffers and hashed text
/// summaries for the current page are retained, keeping working memory bounded.
struct CleanupComparisonEngine {
    typealias ProgressHandler = (Double) -> Void
    typealias CancellationCheck = () -> Bool

    private let renderDimension: Int
    private let pixelDifferenceThreshold: UInt8
    private let visualChangeThreshold: Double

    init(renderDimension: Int = 96,
         pixelDifferenceThreshold: UInt8 = 8,
         visualChangeThreshold: Double = 0.001)
    {
        self.renderDimension = max(16, min(renderDimension, 256))
        self.pixelDifferenceThreshold = pixelDifferenceThreshold
        self.visualChangeThreshold = max(0, min(visualChangeThreshold, 1))
    }

    func compare(source: PDFDocument,
                 output: PDFDocument,
                 progress: ProgressHandler? = nil,
                 isCancelled: CancellationCheck = { false }) throws -> CleanupComparisonResult
    {
        let sourcePageCount = source.pageCount
        let outputPageCount = output.pageCount
        let comparisonPageCount = max(sourcePageCount, outputPageCount)
        var pages: [CleanupPageComparison] = []
        pages.reserveCapacity(comparisonPageCount)

        if comparisonPageCount == 0 {
            if isCancelled() {
                throw CleanupComparisonError.cancelled
            }
            progress?(1)
        }

        for index in 0 ..< comparisonPageCount {
            if isCancelled() {
                throw CleanupComparisonError.cancelled
            }

            let sourcePage = source.page(at: index)
            let outputPage = output.page(at: index)
            let sourceText = textSummary(for: sourcePage)
            let outputText = textSummary(for: outputPage)
            let visualDifference = try visualDifferenceRatio(
                sourcePage: sourcePage,
                outputPage: outputPage,
                pageNumber: index + 1
            )
            let textChanged = sourceText != outputText
            let classification: CleanupPageClassification = if sourcePage == nil || outputPage == nil || visualDifference > visualChangeThreshold {
                .visualChanged
            } else if textChanged {
                .textLayerChanged
            } else {
                .unchanged
            }

            pages.append(CleanupPageComparison(
                pageNumber: index + 1,
                sourceTextFingerprint: sourceText?.fingerprint,
                outputTextFingerprint: outputText?.fingerprint,
                textCharacterCountDelta: (outputText?.characterCount ?? 0) - (sourceText?.characterCount ?? 0),
                visualDifferenceRatio: visualDifference,
                classification: classification
            ))
            progress?(Double(index + 1) / Double(comparisonPageCount))
        }

        let sourceMetadata = metadataLabels(in: source)
        let outputMetadata = metadataLabels(in: output)
        return CleanupComparisonResult(
            sourcePageCount: sourcePageCount,
            outputPageCount: outputPageCount,
            pages: pages,
            metadataFieldsRemoved: Self.metadataFields.compactMap { field in
                sourceMetadata.contains(field.label) && !outputMetadata.contains(field.label) ? field.label : nil
            },
            metadataFieldsRemaining: Self.metadataFields.compactMap { field in
                outputMetadata.contains(field.label) ? field.label : nil
            }
        )
    }
}

private extension CleanupComparisonEngine {
    struct TextSummary: Equatable {
        let fingerprint: String
        let characterCount: Int
    }

    struct MetadataField {
        let attribute: PDFDocumentAttribute
        let label: String
    }

    static let metadataFields: [MetadataField] = [
        MetadataField(attribute: .titleAttribute, label: "Title"),
        MetadataField(attribute: .authorAttribute, label: "Author"),
        MetadataField(attribute: .subjectAttribute, label: "Subject"),
        MetadataField(attribute: .keywordsAttribute, label: "Keywords"),
        MetadataField(attribute: .creatorAttribute, label: "Creator"),
        MetadataField(attribute: .producerAttribute, label: "Producer"),
        MetadataField(attribute: .creationDateAttribute, label: "Creation Date"),
        MetadataField(attribute: .modificationDateAttribute, label: "Modification Date"),
    ]

    func textSummary(for page: PDFPage?) -> TextSummary? {
        guard let page else { return nil }
        let normalized = normalizeExtractableText(page.string ?? "")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return TextSummary(
            fingerprint: digest.map { String(format: "%02x", $0) }.joined(),
            characterCount: normalized.count
        )
    }

    func normalizeExtractableText(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func metadataLabels(in document: PDFDocument) -> Set<String> {
        guard let attributes = document.documentAttributes else { return [] }
        return Set(Self.metadataFields.compactMap { field in
            let value = attributes[field.attribute] ?? attributes[field.attribute.rawValue]
            return value == nil ? nil : field.label
        })
    }

    func visualDifferenceRatio(sourcePage: PDFPage?,
                               outputPage: PDFPage?,
                               pageNumber: Int) throws -> Double
    {
        switch (sourcePage, outputPage) {
        case (nil, nil):
            return 0
        case (nil, _), (_, nil):
            return 1
        case let (sourcePage?, outputPage?):
            guard let sourcePixels = render(page: sourcePage),
                  let outputPixels = render(page: outputPage)
            else {
                throw CleanupComparisonError.couldNotRenderPage(pageNumber)
            }
            var changedPixelCount = 0
            let pixelCount = renderDimension * renderDimension
            for pixel in 0 ..< pixelCount {
                let offset = pixel * 4
                let redDifference = channelDifference(sourcePixels[offset], outputPixels[offset])
                let greenDifference = channelDifference(sourcePixels[offset + 1], outputPixels[offset + 1])
                let blueDifference = channelDifference(sourcePixels[offset + 2], outputPixels[offset + 2])
                if max(redDifference, max(greenDifference, blueDifference)) > pixelDifferenceThreshold {
                    changedPixelCount += 1
                }
            }
            return Double(changedPixelCount) / Double(pixelCount)
        }
    }

    func render(page: PDFPage) -> [UInt8]? {
        let pixelCount = renderDimension * renderDimension
        var pixels = [UInt8](repeating: 255, count: pixelCount * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: renderDimension,
                      height: renderDimension,
                      bitsPerComponent: 8,
                      bytesPerRow: renderDimension * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return false
            }

            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: renderDimension, height: renderDimension))
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { return false }
            let target = CGFloat(renderDimension)
            let scale = min(target / bounds.width, target / bounds.height)
            let horizontalInset = (target - bounds.width * scale) / 2
            let verticalInset = (target - bounds.height * scale) / 2
            context.translateBy(x: horizontalInset, y: verticalInset)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
            return true
        }
        return rendered ? pixels : nil
    }

    func channelDifference(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}
