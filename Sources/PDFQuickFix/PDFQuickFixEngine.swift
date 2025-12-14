import Foundation
import AppKit
import PDFKit
import Vision
import CoreGraphics
import CoreText

import PDFQuickFixKit

protocol OCRTextCandidate {
    var string: String { get }
    func boundingBoxNormalized(for range: Range<String.Index>) -> CGRect?
}

protocol OCRProviding {
    func recognizeText(in image: CGImage, languages: [String]) throws -> [OCRTextCandidate]
}

struct VisionOCRProvider: OCRProviding {
    private struct Candidate: OCRTextCandidate {
        let recognizedText: VNRecognizedText

        var string: String { recognizedText.string }

        func boundingBoxNormalized(for range: Range<String.Index>) -> CGRect? {
            (try? recognizedText.boundingBox(for: range))?.boundingBox
        }
    }

    func recognizeText(in image: CGImage, languages: [String]) throws -> [OCRTextCandidate] {
        let request = VNRecognizeTextRequest()
        request.minimumTextHeight = 0.01
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = []
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []

        return observations.compactMap { observation in
            observation.topCandidates(1).first.map { Candidate(recognizedText: $0) }
        }
    }
}

struct RedactionReport: Hashable {
    struct Page: Hashable {
        let pageIndex: Int
        let redactionRectCount: Int
        let suppressedOCRRunCount: Int
    }

    /// Only pages where at least one redaction rectangle was applied.
    let pagesWithRedactions: [Page]

    var totalRedactionRectCount: Int {
        pagesWithRedactions.reduce(into: 0) { $0 += $1.redactionRectCount }
    }

    var totalSuppressedOCRRunCount: Int {
        pagesWithRedactions.reduce(into: 0) { $0 += $1.suppressedOCRRunCount }
    }
}

struct QuickFixResult: Hashable {
    let outputURL: URL
    let redactionReport: RedactionReport
}

final class PDFQuickFixEngine {
    let options: QuickFixOptions
    let languages: [String]
    let ocrProvider: OCRProviding
    let queue = DispatchQueue(label: "pdfquickfix.engine", qos: .userInitiated)
    
    init(options: QuickFixOptions = .init(),
         languages: [String] = ["tr-TR", "en-US"],
         ocrProvider: OCRProviding = VisionOCRProvider()) {
        self.options = options
        self.languages = languages
        self.ocrProvider = ocrProvider
    }
    
    func process(inputURL: URL,
                 outputURL: URL? = nil,
                 redactionPatterns: [RedactionPattern] = DefaultPatterns.defaults(),
                 customRegexes: [NSRegularExpression] = [],
                 findReplace: [FindReplaceRule] = [],
                 manualRedactions: [Int:[CGRect]] = [:]) throws -> URL {
        try processWithReport(
            inputURL: inputURL,
            outputURL: outputURL,
            redactionPatterns: redactionPatterns,
            customRegexes: customRegexes,
            findReplace: findReplace,
            manualRedactions: manualRedactions
        ).outputURL
    }

    func processWithReport(inputURL: URL,
                           outputURL: URL? = nil,
                           redactionPatterns: [RedactionPattern] = DefaultPatterns.defaults(),
                           customRegexes: [NSRegularExpression] = [],
                           findReplace: [FindReplaceRule] = [],
                           manualRedactions: [Int:[CGRect]] = [:]) throws -> QuickFixResult {
        let doc: PDFDocument
        do {
            // Repair/Pre-process
            let repairedURL = try PDFRepairService().repairIfNeeded(inputURL: inputURL)

            // Load without rebuilding, as the engine will process/rasterize pages anyway.
            let loadOptions = PDFDocumentSanitizer.Options(rebuildMode: .never, sanitizeAnnotations: false, sanitizeOutline: false)
            doc = try PDFDocumentSanitizer.loadDocument(at: repairedURL, options: loadOptions)
        } catch {
            throw NSError(domain: "PDFQuickFix", code: -1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
        }

        let outURL: URL = outputURL ?? inputURL.deletingPathExtension().appendingPathExtension("fixed.pdf")

        let pageCount = doc.pageCount
        var processedPages: [PageProcessResult] = []
        processedPages.reserveCapacity(pageCount)

        var pagesWithRedactions: [RedactionReport.Page] = []
        pagesWithRedactions.reserveCapacity(pageCount)

        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            let (result, pageReport) = try processPage(page: page,
                                                       pageIndex: i,
                                                       manualRedactions: manualRedactions[i] ?? [],
                                                       redactionPatterns: redactionPatterns,
                                                       customRegexes: customRegexes,
                                                       findReplace: findReplace)
            processedPages.append(result)
            if let pageReport {
                pagesWithRedactions.append(pageReport)
            }
        }

        try writePDF(pages: processedPages, to: outURL)
        return QuickFixResult(
            outputURL: outURL,
            redactionReport: RedactionReport(pagesWithRedactions: pagesWithRedactions)
        )
    }
    
    private func processPage(page: PDFPage,
                             pageIndex: Int,
                             manualRedactions: [CGRect],
                             redactionPatterns: [RedactionPattern],
                             customRegexes: [NSRegularExpression],
                             findReplace: [FindReplaceRule]) throws -> (PageProcessResult, RedactionReport.Page?) {
        guard let cgPage = page.pageRef else {
            throw NSError(domain: "PDFQuickFix", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing CGPDFPage"])
        }

        let renderBox: CGPDFBox = .mediaBox
        let sourceBox = cgPage.getBoxRect(renderBox)
        let rotationAngle = ((cgPage.rotationAngle % 360) + 360) % 360
        let pageSizePoints: CGSize
        if rotationAngle == 90 || rotationAngle == 270 {
            pageSizePoints = CGSize(width: sourceBox.height, height: sourceBox.width)
        } else {
            pageSizePoints = sourceBox.size
        }

        let widthPx = max(1, Int(ceil(pointsToPixels(pageSizePoints.width, dpi: options.dpi))))
        let heightPx = max(1, Int(ceil(pointsToPixels(pageSizePoints.height, dpi: options.dpi))))
        let imageBoundsPx = CGRect(x: 0, y: 0, width: CGFloat(widthPx), height: CGFloat(heightPx))
        let suppressionEpsilonPx: CGFloat = 1.0
        
        // Render original page into bitmap
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: widthPx, height: heightPx,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "PDFQuickFix", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap context"])
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

        let targetRectPx = CGRect(x: 0, y: 0, width: CGFloat(widthPx), height: CGFloat(heightPx))
        let pageToPixelTransform = cgPage.getDrawingTransform(renderBox,
                                                              rect: targetRectPx,
                                                              rotate: 0,
                                                              preserveAspectRatio: true)
        ctx.saveGState()
        ctx.concatenate(pageToPixelTransform)
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()
        
        guard let baseImage = ctx.makeImage() else {
            throw NSError(domain: "PDFQuickFix", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to rasterize page"])
        }
        
        // OCR with Vision if needed for redaction/find-replace/OCR layer
        var textCandidates: [OCRTextCandidate] = []
        if options.doOCR || !redactionPatterns.isEmpty || !customRegexes.isEmpty || !findReplace.isEmpty {
            textCandidates = (try? ocrProvider.recognizeText(in: baseImage, languages: languages)) ?? []
        }
        
        // Build redaction rectangles and replacement runs
        let allRegexes = redactionPatterns.map { $0.regex } + customRegexes
        
        var redactionRectsPx: [CGRect] = []
        var replacementRunsPx: [(rect: CGRect, replacement: String)] = []
        var textRuns: [RecognizedRun] = []
        
        for rect in manualRedactions {
            let converted = rect.applying(pageToPixelTransform)
                .insetBy(dx: -options.redactionPadding, dy: -options.redactionPadding)
                .standardized
                .intersection(imageBoundsPx)
            if !converted.isNull, converted.width > 0, converted.height > 0 {
                redactionRectsPx.append(converted)
            }
        }
        
        for candidate in textCandidates {
            let text = candidate.string
            let textLength = text.utf16.count
            let fullRange = NSRange(location: 0, length: textLength)
            
            // ranges for redactions
            var redactionRanges: [NSRange] = []
            for rx in allRegexes {
                rx.enumerateMatches(in: text, options: [], range: fullRange) { m, _, _ in
                    if let r = m?.range { redactionRanges.append(r) }
                }
            }
            // ranges for replacements
            var replacements: [(range: NSRange, replacement: String)] = []
            for rule in findReplace {
                let pattern = NSRegularExpression.escapedPattern(for: rule.find)
                if let rx = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    rx.enumerateMatches(in: text, options: [], range: fullRange) { m, _, _ in
                        if let r = m?.range {
                            replacements.append((r, rule.replace))
                        }
                    }
                }
            }
            
            enum SegmentKind: Equatable {
                case keep
                case replace(String)
                case skip
            }

            struct Segment {
                let start: Int
                let end: Int
                let kind: SegmentKind
            }

            func mergeAdjacent(_ segments: [Segment]) -> [Segment] {
                guard var last = segments.first else { return [] }
                var merged: [Segment] = []
                for seg in segments.dropFirst() {
                    if seg.start == last.end, seg.kind == last.kind {
                        last = Segment(start: last.start, end: seg.end, kind: last.kind)
                    } else {
                        merged.append(last)
                        last = seg
                    }
                }
                merged.append(last)
                return merged
            }

            func applySpan(start: Int, end: Int, kind: SegmentKind, to segments: [Segment]) -> [Segment] {
                guard start < end else { return segments }
                var next: [Segment] = []
                next.reserveCapacity(segments.count + 2)

                for seg in segments {
                    if end <= seg.start || start >= seg.end {
                        next.append(seg)
                        continue
                    }

                    if start > seg.start {
                        next.append(Segment(start: seg.start, end: start, kind: seg.kind))
                    }

                    let overlapStart = max(start, seg.start)
                    let overlapEnd = min(end, seg.end)
                    next.append(Segment(start: overlapStart, end: overlapEnd, kind: kind))

                    if end < seg.end {
                        next.append(Segment(start: overlapEnd, end: seg.end, kind: seg.kind))
                    }
                }

                return mergeAdjacent(next.sorted { $0.start < $1.start })
            }

            var segments: [Segment] = textLength == 0 ? [] : [Segment(start: 0, end: textLength, kind: .keep)]

            // Precedence: regex redaction (skip) must override replacement.
            for replacement in replacements {
                let start = replacement.range.location
                let end = replacement.range.location + replacement.range.length
                let repl = ruleReplacement(text: substring(forRange: replacement.range, in: text), repl: replacement.replacement)
                segments = applySpan(start: start, end: end, kind: .replace(repl), to: segments)
            }

            for range in redactionRanges {
                let start = range.location
                let end = range.location + range.length
                segments = applySpan(start: start, end: end, kind: .skip, to: segments)
            }
            
            // Convert segments to runs with rectangles
            for seg in segments {
                let r = NSRange(location: seg.start, length: seg.end - seg.start)
                guard let range = Range(r, in: text), let bb = candidate.boundingBoxNormalized(for: range) else { continue }

                let rectPx = visionRectToPixelRect(bb, imageSize: CGSize(width: baseImage.width, height: baseImage.height))
                    .standardized
                    .intersection(imageBoundsPx)
                if rectPx.isNull || rectPx.width <= 0 || rectPx.height <= 0 { continue }

                switch seg.kind {
                case .skip:
                    let padded = rectPx
                        .insetBy(dx: -options.redactionPadding, dy: -options.redactionPadding)
                        .standardized
                        .intersection(imageBoundsPx)
                    if !padded.isNull, padded.width > 0, padded.height > 0 {
                        redactionRectsPx.append(padded)
                    }
                case .replace(let repl):
                    replacementRunsPx.append((rectPx, repl))
                    textRuns.append(RecognizedRun(kind: .replace(repl), rect: rectPx))
                case .keep:
                    let s = substring(forRange: r, in: text)
                    textRuns.append(RecognizedRun(kind: .keep(s), rect: rectPx))
                }
            }
        }

        // Redaction must win, even with slight rounding differences.
        // Use the same epsilon-expanded list both for union fast-path and per-rect intersection checks.
        let redactionRectsForOverlapPx = redactionRectsPx.map { rect in
            rect.insetBy(dx: -suppressionEpsilonPx, dy: -suppressionEpsilonPx)
        }
        let redactionUnionBoundsPx = redactionRectsForOverlapPx.reduce(CGRect.null) { $0.union($1) }
        replacementRunsPx.removeAll { run in
            guard !redactionRectsForOverlapPx.isEmpty else { return false }
            if !run.rect.intersects(redactionUnionBoundsPx) { return false }
            return redactionRectsForOverlapPx.contains(where: { $0.intersects(run.rect) })
        }
        
        // Draw redactions and replacements onto image
        guard let editCtx = CGContext(data: nil, width: widthPx, height: heightPx,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "PDFQuickFix", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unable to create edit context"])
        }
        editCtx.interpolationQuality = .high
        // original
        editCtx.draw(baseImage, in: CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
        
        // redact
        editCtx.setFillColor(NSColor.black.cgColor)
        for r in redactionRectsPx { editCtx.fill(r) }
        
        // replace (white out then draw text)
        for run in replacementRunsPx {
            editCtx.setFillColor(NSColor.white.cgColor)
            editCtx.fill(run.rect)
            // draw replacement visible
            let fontSizePx = max(10, run.rect.height * 0.85)
            let font = NSFont.systemFont(ofSize: fontSizePx)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            let attributed = NSAttributedString(string: run.replacement, attributes: attrs)
            // Flip context for text drawing
            editCtx.saveGState()
            editCtx.translateBy(x: run.rect.minX, y: run.rect.minY + run.rect.height)
            editCtx.scaleBy(x: 1, y: -1)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: run.rect.width, height: run.rect.height), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
            CTFrameDraw(frame, editCtx)
            editCtx.restoreGState()
        }
        
        guard let finalImage = editCtx.makeImage() else {
            throw NSError(domain: "PDFQuickFix", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to finalize page image"])
        }
        
        // Prepare OCR text runs in POINTS (for invisible overlay)
        var runsInPoints: [RecognizedRun] = []
        var suppressedOCRRunCount = 0
        if options.doOCR {
            let filteredTextRuns: [RecognizedRun] = textRuns.filter { run in
                guard !redactionRectsForOverlapPx.isEmpty else { return true }
                if !run.rect.intersects(redactionUnionBoundsPx) { return true }
                return !redactionRectsForOverlapPx.contains(where: { $0.intersects(run.rect) })
            }
            suppressedOCRRunCount = textRuns.count - filteredTextRuns.count

            for r in filteredTextRuns {
                let rectPt = CGRect(
                    x: pixelsToPoints(r.rect.origin.x, dpi: options.dpi),
                    y: pixelsToPoints(r.rect.origin.y, dpi: options.dpi),
                    width: pixelsToPoints(r.rect.width, dpi: options.dpi),
                    height: pixelsToPoints(r.rect.height, dpi: options.dpi)
                )
                runsInPoints.append(RecognizedRun(kind: r.kind, rect: rectPt))
            }
        }

        let pageReport: RedactionReport.Page? = redactionRectsPx.isEmpty ? nil : RedactionReport.Page(
            pageIndex: pageIndex,
            redactionRectCount: redactionRectsPx.count,
            suppressedOCRRunCount: suppressedOCRRunCount
        )

        return (PageProcessResult(pageSizePoints: pageSizePoints, cgImage: finalImage, textRunsInPoints: runsInPoints), pageReport)
    }
    
    private func ruleReplacement(text: String, repl: String) -> String {
        return repl // basic: ignore capture groups; could extend.
    }

    private func substring(forRange range: NSRange, in text: String) -> String {
        guard let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    private func writePDF(pages: [PageProcessResult], to url: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "PDFQuickFix", code: -7, userInfo: [NSLocalizedDescriptionKey: "Cannot create data consumer"])
        }
        guard let firstPage = pages.first else {
            throw NSError(domain: "PDFQuickFix", code: -9, userInfo: [NSLocalizedDescriptionKey: "No pages to write"])
        }

        var mediaBox = CGRect(origin: .zero, size: firstPage.pageSizePoints)
        guard let pdfCtx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFQuickFix", code: -8, userInfo: [NSLocalizedDescriptionKey: "Cannot create PDF context"])
        }
        
        for page in pages {
            let box = CGRect(origin: .zero, size: page.pageSizePoints)
            pdfCtx.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
            // draw raster page
            pdfCtx.draw(page.cgImage, in: box)
            
            // Draw invisible text overlay runs
            for run in page.textRunsInPoints {
                let rect = CGRect(x: run.rect.origin.x,
                                  y: run.rect.origin.y,
                                  width: run.rect.size.width,
                                  height: run.rect.size.height)
                let text: String
                switch run.kind {
                case .keep(let s): text = s
                case .replace(let s): text = s
                case .skip: continue
                }
                if text.isEmpty { continue }
                
                let fontSize = max(8, rect.height * 0.85)
                let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                let attr = [kCTFontAttributeName as NSAttributedString.Key: font]
                let attrStr = NSAttributedString(string: text, attributes: attr)
                let line = CTLineCreateWithAttributedString(attrStr as CFAttributedString)
                
                pdfCtx.saveGState()
                pdfCtx.setTextDrawingMode(.invisible) // searchable but not visible
                pdfCtx.textMatrix = .identity
                pdfCtx.translateBy(x: rect.minX, y: rect.minY + (rect.height - fontSize) * 0.1)
                CTLineDraw(line, pdfCtx)
                pdfCtx.restoreGState()
            }
            
            pdfCtx.endPDFPage()
        }
        pdfCtx.closePDF()
        try data.write(to: url, options: .atomic)
    }
}
