import Foundation
import AppKit
import PDFKit
import Vision
import CoreGraphics
import CoreText

import PDFQuickFixKit

typealias QuickFixCancellationChecker = () -> Bool

enum PDFQuickFixEngineError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Operation cancelled."
        }
    }
}

final class PDFQuickFixEngine {
    let options: QuickFixOptions
    let languages: [String]
    let queue = DispatchQueue(label: "pdfquickfix.engine", qos: .userInitiated)
    private let localOCRProviderOverride: LocalOCRProviding?
    private let cloudOCRProviderOverride: CloudOCRProviding?
    private let localOCRTimeout: TimeInterval = 12
    private let cloudOCRTimeout: TimeInterval = 20
    
    init(options: QuickFixOptions = .init(),
         languages: [String] = ["tr-TR", "en-US"],
         localOCRProvider: LocalOCRProviding? = nil,
         cloudOCRProvider: CloudOCRProviding? = nil) {
        self.options = options
        self.languages = languages
        self.localOCRProviderOverride = localOCRProvider
        self.cloudOCRProviderOverride = cloudOCRProvider
    }

    func processResult(inputURL: URL,
                       outputURL: URL? = nil,
                       redactionPatterns: [RedactionPattern] = DefaultPatterns.defaults(),
                       customRegexes: [NSRegularExpression] = [],
                       findReplace: [FindReplaceRule] = [],
                       manualRedactions: [Int:[CGRect]] = [:],
                       shouldCancel: QuickFixCancellationChecker? = nil,
                       progress: ((Int, Int) -> Void)? = nil) throws -> QuickFixResult {
        try checkCancellation(shouldCancel)

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
        let visionProvider = VisionOCRProvider(languages: languages)
        var processedPages: [PageProcessResult] = []
        processedPages.reserveCapacity(pageCount)

        var pagesWithRedactions: [Int] = []
        var totalRedactionRectCount = 0
        var suppressedOCRRunCount = 0
        var localOCRPages = 0
        var cloudOCRPages = 0
        var visionOCRPages = 0
        var ocrDisabledPages = 0
        var emptyOCRPages = 0
        var emptyOCRPageIndices: [Int] = []
        var localOCRFallbackCount = 0
        let localOCRProvider = options.ocrProvider == .autoLocalOCR
            ? (localOCRProviderOverride ?? selectLocalOCRProvider(preferredModel: options.localOCRModel))
            : nil
        let trimmedCloudKey = options.cloudOcrApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cloudOCRProvider = (options.cloudOcrEnabled && !trimmedCloudKey.isEmpty)
            ? (cloudOCRProviderOverride ?? GoogleVisionOCRProvider(apiKey: trimmedCloudKey, languages: languages))
            : nil

        for i in 0..<pageCount {
            try checkCancellation(shouldCancel)
            guard let page = doc.page(at: i) else { continue }
            let result = try processPage(page: page,
                                         pageIndex: i,
                                         manualRedactions: manualRedactions[i] ?? [],
                                         redactionPatterns: redactionPatterns,
                                         customRegexes: customRegexes,
                                         findReplace: findReplace,
                                         localOCRProvider: localOCRProvider,
                                         cloudOCRProvider: cloudOCRProvider,
                                         visionProvider: visionProvider)
            try checkCancellation(shouldCancel)

            if result.redactionRectCount > 0 {
                pagesWithRedactions.append(i)
            }
            totalRedactionRectCount += result.redactionRectCount
            suppressedOCRRunCount += result.suppressedOCRRunCount
            switch result.ocrSource {
            case .localOCR:
                localOCRPages += 1
            case .cloudOCR:
                cloudOCRPages += 1
            case .vision:
                visionOCRPages += 1
            case .none:
                ocrDisabledPages += 1
            }
            if options.doOCR, result.ocrRunCount == 0 {
                emptyOCRPages += 1
                emptyOCRPageIndices.append(i)
            }
            if result.localOCREligible && !result.localOCRSucceeded {
                localOCRFallbackCount += 1
            }

            processedPages.append(result)
            progress?(i + 1, pageCount)
        }

        try writePDF(pages: processedPages, to: outURL)

        let report = RedactionReport(pagesWithRedactions: pagesWithRedactions,
                                     totalRedactionRectCount: totalRedactionRectCount,
                                     suppressedOCRRunCount: suppressedOCRRunCount)
        let ocrReport = OCRReport(
            totalPages: pageCount,
            localOCRPages: localOCRPages,
            cloudOCRPages: cloudOCRPages,
            visionOCRPages: visionOCRPages,
            ocrDisabledPages: ocrDisabledPages,
            emptyOCRPages: emptyOCRPages,
            emptyOCRPageIndices: emptyOCRPageIndices,
            localOCRFallbackCount: localOCRFallbackCount
        )
        return QuickFixResult(
            outputURL: outURL,
            isTemporaryOutput: outputURL == nil,
            previewPageIndex: pagesWithRedactions.first ?? emptyOCRPageIndices.first,
            redactionReport: report,
            ocrReport: ocrReport
        )
    }

    func process(inputURL: URL,
                 outputURL: URL? = nil,
                 redactionPatterns: [RedactionPattern] = DefaultPatterns.defaults(),
                 customRegexes: [NSRegularExpression] = [],
                 findReplace: [FindReplaceRule] = [],
                 manualRedactions: [Int:[CGRect]] = [:],
                 shouldCancel: QuickFixCancellationChecker? = nil,
                 progress: ((Int, Int) -> Void)? = nil) throws -> URL {
        try processResult(inputURL: inputURL,
                          outputURL: outputURL,
                          redactionPatterns: redactionPatterns,
                          customRegexes: customRegexes,
                          findReplace: findReplace,
                          manualRedactions: manualRedactions,
                          shouldCancel: shouldCancel,
                          progress: progress).outputURL
    }
    
    private func processPage(page: PDFPage,
                             pageIndex: Int,
                             manualRedactions: [CGRect],
                             redactionPatterns: [RedactionPattern],
                             customRegexes: [NSRegularExpression],
                             findReplace: [FindReplaceRule],
                             localOCRProvider: LocalOCRProviding?,
                             cloudOCRProvider: CloudOCRProviding?,
                             visionProvider: VisionOCRProvider) throws -> PageProcessResult {
        guard let cgPage = page.pageRef else {
            throw NSError(domain: "PDFQuickFix", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing CGPDFPage"])
        }
        let mediaBox = cgPage.getBoxRect(.mediaBox)
        let widthPx = Int(pointsToPixels(mediaBox.width, dpi: options.dpi))
        let heightPx = Int(pointsToPixels(mediaBox.height, dpi: options.dpi))
        
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
        // Scale to pixel space
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(widthPx) / mediaBox.width, y: CGFloat(heightPx) / mediaBox.height)
        ctx.drawPDFPage(cgPage)
        ctx.restoreGState()
        
        guard let baseImage = ctx.makeImage() else {
            throw NSError(domain: "PDFQuickFix", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to rasterize page"])
        }
        
        let needsVisionForRedaction = !redactionPatterns.isEmpty || !customRegexes.isEmpty || !findReplace.isEmpty
        let hasManualRedactions = !manualRedactions.isEmpty
        let allowLocalOverlay = options.doOCR
            && options.ocrProvider == .autoLocalOCR
            && !needsVisionForRedaction
            && !hasManualRedactions

        // OCR with Vision if needed for redaction/find-replace or when local OCR is not used
        var textObservations: [VNRecognizedTextObservation] = []
        if needsVisionForRedaction || (options.doOCR && !allowLocalOverlay) {
            if let obs = try? visionProvider.recognizeText(cgImage: baseImage) {
                textObservations = obs
            }
        }
        
        // Build redaction rectangles and replacement runs
        let allRegexes = redactionPatterns.map { $0.regex } + customRegexes
        
        let scaleX = CGFloat(widthPx) / mediaBox.width
        let scaleY = CGFloat(heightPx) / mediaBox.height
        var redactionRectsPx: [CGRect] = []
        var replacementRunsPx: [(rect: CGRect, replacement: String)] = []
        var visionTextRuns: [RecognizedRun] = []
        var suppressedOCRRunsByRedactionMatches = 0
        var didApplyVision = false
        
        for rect in manualRedactions {
            let converted = CGRect(
                x: rect.origin.x * scaleX,
                y: rect.origin.y * scaleY,
                width: rect.size.width * scaleX,
                height: rect.size.height * scaleY
            )
            redactionRectsPx.append(converted)
        }
        
        let applyVisionObservations: ([VNRecognizedTextObservation]) -> Void = { [self] observations in
            guard !didApplyVision else { return }
            didApplyVision = true

            for ob in observations {
                guard let best = ob.topCandidates(1).first else { continue }
                let text = best.string
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

                // Build disjoint segments
                var cursor = 0
                var special: [(start: Int, end: Int, kind: RecognizedRun.Kind)] = []
                special += redactionRanges.map { ( $0.location, $0.location+$0.length, .skip ) }
                special += replacements.map {
                    ( $0.range.location,
                      $0.range.location+$0.range.length,
                      .replace(self.ruleReplacement(text: self.substring(forRange: $0.range, in: text), repl: $0.replacement)) )
                }
                special.sort { $0.start < $1.start }

                var segments: [(start: Int, end: Int, kind: RecognizedRun.Kind)] = []
                var idx = 0
                while cursor < textLength {
                    if idx < special.count {
                        let s = special[idx].start
                        let e = special[idx].end
                        let kind = special[idx].kind
                        if s > cursor {
                            let substrRange = NSRange(location: cursor, length: s - cursor)
                            let substr = self.substring(forRange: substrRange, in: text)
                            segments.append((cursor, s, .keep(substr)))
                            cursor = s
                        } else {
                            segments.append((s, e, kind))
                            cursor = e
                            idx += 1
                        }
                    } else {
                        let substrRange = NSRange(location: cursor, length: textLength - cursor)
                        let substr = self.substring(forRange: substrRange, in: text)
                        segments.append((cursor, textLength, .keep(substr)))
                        cursor = textLength
                    }
                }

                // Convert segments to runs with rectangles
                for seg in segments {
                    let r = NSRange(location: seg.start, length: seg.end - seg.start)
                    if let range = Range(r, in: text), let box = try? best.boundingBox(for: range) {
                        let rectPx = visionRectToPixelRect(box.boundingBox,
                                                           imageSize: CGSize(width: baseImage.width, height: baseImage.height))
                        switch seg.kind {
                        case .skip:
                            let padded = rectPx.insetBy(dx: -self.options.redactionPadding, dy: -self.options.redactionPadding)
                            redactionRectsPx.append(padded)
                            if self.options.doOCR {
                                suppressedOCRRunsByRedactionMatches += 1
                            }
                        case .replace(let repl):
                            replacementRunsPx.append((rectPx, repl))
                            visionTextRuns.append(RecognizedRun(kind: .replace(repl), rectInPixels: rectPx))
                        case .keep(let s):
                            visionTextRuns.append(RecognizedRun(kind: .keep(s), rectInPixels: rectPx))
                        }
                    }
                }
            }
        }

        if !textObservations.isEmpty {
            applyVisionObservations(textObservations)
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
        let localEligible = options.doOCR && allowLocalOverlay && localOCRProvider != nil
        var localSucceeded = false
        var overlayRuns: [RecognizedRun] = []
        var ocrSource: OCRSource = .none

        if options.doOCR {
            if localEligible, let provider = localOCRProvider,
               let localRuns = runLocalOCROverlay(provider: provider, image: baseImage) {
                overlayRuns = localRuns
                localSucceeded = true
                ocrSource = .localOCR
            } else {
                if allowLocalOverlay, let cloudProvider = cloudOCRProvider,
                   let cloudRuns = runCloudOCROverlay(provider: cloudProvider, image: baseImage) {
                    overlayRuns = cloudRuns
                    ocrSource = .cloudOCR
                } else {
                    if visionTextRuns.isEmpty {
                        if textObservations.isEmpty, let obs = try? visionProvider.recognizeText(cgImage: baseImage) {
                            textObservations = obs
                        }
                        if !textObservations.isEmpty {
                            applyVisionObservations(textObservations)
                        }
                    }
                    overlayRuns = visionTextRuns
                    ocrSource = .vision
                }
            }
        }

        var runsInPoints: [RecognizedRun] = []
        if options.doOCR {
            var suppressedByOverlap = 0
            for r in overlayRuns {
                if !redactionRectsPx.isEmpty, redactionRectsPx.contains(where: { $0.intersects(r.rectInPixels) }) {
                    suppressedByOverlap += 1
                    continue
                }
                let rectPt = CGRect(
                    x: pixelsToPoints(r.rectInPixels.origin.x, dpi: options.dpi),
                    y: pixelsToPoints(r.rectInPixels.origin.y, dpi: options.dpi),
                    width: pixelsToPoints(r.rectInPixels.width, dpi: options.dpi),
                    height: pixelsToPoints(r.rectInPixels.height, dpi: options.dpi)
                )
                runsInPoints.append(RecognizedRun(kind: r.kind, rectInPixels: rectPt))
            }
            suppressedOCRRunsByRedactionMatches += suppressedByOverlap
        }
        
        return PageProcessResult(pageSizePoints: mediaBox.size,
                                 cgImage: finalImage,
                                 textRunsInPoints: runsInPoints,
                                 redactionRectCount: redactionRectsPx.count,
                                 suppressedOCRRunCount: options.doOCR ? suppressedOCRRunsByRedactionMatches : 0,
                                 ocrSource: ocrSource,
                                 ocrRunCount: overlayRuns.count,
                                 localOCREligible: localEligible,
                                 localOCRSucceeded: localSucceeded)
    }
    
    private func ruleReplacement(text: String, repl: String) -> String {
        return repl // basic: ignore capture groups; could extend.
    }

    private func substring(forRange range: NSRange, in text: String) -> String {
        guard let swiftRange = Range(range, in: text) else { return "" }
        return String(text[swiftRange])
    }

    private func checkCancellation(_ shouldCancel: QuickFixCancellationChecker?) throws {
        if shouldCancel?() == true {
            throw PDFQuickFixEngineError.cancelled
        }
    }

    private func runLocalOCROverlay(provider: LocalOCRProviding, image: CGImage) -> [RecognizedRun]? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[RecognizedRun], Error>?
        DispatchQueue.global(qos: .userInitiated).async {
            result = Result { try provider.recognizeTextLines(cgImage: image) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + localOCRTimeout) == .timedOut {
            return nil
        }
        return try? result?.get()
    }

    private func runCloudOCROverlay(provider: CloudOCRProviding, image: CGImage) -> [RecognizedRun]? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[RecognizedRun], Error>?
        DispatchQueue.global(qos: .userInitiated).async {
            result = Result { try provider.recognizeTextLines(cgImage: image) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + cloudOCRTimeout) == .timedOut {
            return nil
        }
        return try? result?.get()
    }

    private func selectLocalOCRProvider(preferredModel: String) -> LocalOCRProviding? {
        let trimmedPreferred = preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultCandidates = ["qwen2.5vl:7b", "minicpm-v:8b", "deepseek-ocr:3b"]
        var candidates: [String] = []
        if !trimmedPreferred.isEmpty {
            candidates.append(trimmedPreferred)
        }
        for candidate in defaultCandidates where !candidates.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidates.append(candidate)
        }

        for name in candidates {
            let provider = makeLocalOCRProvider(modelName: name)
            if provider.isAvailable() {
                return provider
            }
        }
        return nil
    }

    private func makeLocalOCRProvider(modelName: String) -> LocalOCRProviding {
        if modelName.lowercased().contains("deepseek-ocr") {
            return OllamaDeepSeekOCRProvider(modelName: modelName)
        }
        return OllamaVisionOCRProvider(modelName: modelName)
    }
    
    private func writePDF(pages: [PageProcessResult], to url: URL) throws {
        guard let firstPage = pages.first else {
            throw NSError(domain: "PDFQuickFix", code: -9, userInfo: [NSLocalizedDescriptionKey: "No pages to write"])
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "PDFQuickFix", code: -7, userInfo: [NSLocalizedDescriptionKey: "Cannot create data consumer"])
        }
        // Important: CGContext(mediaBox:) must be non-zero; otherwise pages can end up with 0×0 MediaBox,
        // which makes the output PDF appear blank in PDFKit/viewers even if drawing succeeded.
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
                let rect = CGRect(x: run.rectInPixels.origin.x,
                                  y: run.rectInPixels.origin.y,
                                  width: run.rectInPixels.size.width,
                                  height: run.rectInPixels.size.height)
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
