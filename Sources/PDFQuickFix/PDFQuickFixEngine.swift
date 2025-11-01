import Foundation
import AppKit
import PDFKit
import Vision
import CoreGraphics
import CoreText

final class PDFQuickFixEngine {
    let options: QuickFixOptions
    let languages: [String]
    let queue = DispatchQueue(label: "pdfquickfix.engine", qos: .userInitiated)
    
    init(options: QuickFixOptions = .init(), languages: [String] = ["tr-TR", "en-US"]) {
        self.options = options
        self.languages = languages
    }
    
    func process(inputURL: URL,
                 outputURL: URL? = nil,
                 redactionPatterns: [RedactionPattern] = DefaultPatterns.defaults(),
                 customRegexes: [NSRegularExpression] = [],
                 findReplace: [FindReplaceRule] = [],
                 manualRedactions: [Int:[CGRect]] = [:]) throws -> URL {
        
        guard let doc = PDFDocument(url: inputURL) else {
            throw NSError(domain: "PDFQuickFix", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to open PDF"])
        }
        let outURL: URL = outputURL ?? inputURL.deletingPathExtension().appendingPathExtension("fixed.pdf")
        
        let pageCount = doc.pageCount
        var processedPages: [PageProcessResult] = []
        processedPages.reserveCapacity(pageCount)
        
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            let result = try processPage(page: page,
                                         pageIndex: i,
                                         manualRedactions: manualRedactions[i] ?? [],
                                         redactionPatterns: redactionPatterns,
                                         customRegexes: customRegexes,
                                         findReplace: findReplace)
            processedPages.append(result)
        }
        
        try writePDF(pages: processedPages, to: outURL)
        return outURL
    }
    
    private func processPage(page: PDFPage,
                             pageIndex: Int,
                             manualRedactions: [CGRect],
                             redactionPatterns: [RedactionPattern],
                             customRegexes: [NSRegularExpression],
                             findReplace: [FindReplaceRule]) throws -> PageProcessResult {
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
        
        // OCR with Vision if needed for redaction/find-replace/OCR layer
        var textObservations: [VNRecognizedTextObservation] = []
        if options.doOCR || !redactionPatterns.isEmpty || !customRegexes.isEmpty || !findReplace.isEmpty {
            if let obs = try? recognizeText(cgImage: baseImage) {
                textObservations = obs
            }
        }
        
        // Build redaction rectangles and replacement runs
        let allRegexes = redactionPatterns.map { $0.regex } + customRegexes
        
        let scaleX = CGFloat(widthPx) / mediaBox.width
        let scaleY = CGFloat(heightPx) / mediaBox.height
        var redactionRectsPx: [CGRect] = []
        var replacementRunsPx: [(rect: CGRect, replacement: String)] = []
        var textRuns: [RecognizedRun] = []
        
        for rect in manualRedactions {
            let converted = CGRect(
                x: rect.origin.x * scaleX,
                y: rect.origin.y * scaleY,
                width: rect.size.width * scaleX,
                height: rect.size.height * scaleY
            ).insetBy(dx: -options.redactionPadding, dy: -options.redactionPadding)
            redactionRectsPx.append(converted)
        }
        
        for ob in textObservations {
            guard let best = ob.topCandidates(1).first else { continue }
            let text = best.string
            let nsText = text as NSString
            let fullRange = NSRange(location: 0, length: nsText.length)
            
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
            special += replacements.map { ( $0.range.location, $0.range.location+$0.range.length, .replace(ruleReplacement(text: nsText.substring(with: $0.range), repl: $0.replacement)) ) }
            special.sort { $0.start < $1.start }
            
            var segments: [(start: Int, end: Int, kind: RecognizedRun.Kind)] = []
            var idx = 0
            while cursor < nsText.length {
                if idx < special.count {
                    let s = special[idx].start
                    let e = special[idx].end
                    let kind = special[idx].kind
                    if s > cursor {
                        let substr = nsText.substring(with: NSRange(location: cursor, length: s - cursor))
                        segments.append((cursor, s, .keep(substr)))
                        cursor = s
                    } else {
                        segments.append((s, e, kind))
                        cursor = e
                        idx += 1
                    }
                } else {
                    let substr = nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor))
                    segments.append((cursor, nsText.length, .keep(substr)))
                    cursor = nsText.length
                }
            }
            
            // Convert segments to runs with rectangles
            for seg in segments {
                let r = NSRange(location: seg.start, length: seg.end - seg.start)
                if let range = Range(r, in: text), let box = try? best.boundingBox(for: range) {
                    let rectPx = visionRectToPixelRect(box.boundingBox, imageSize: CGSize(width: baseImage.width, height: baseImage.height))
                    switch seg.kind {
                    case .skip:
                        let padded = rectPx.insetBy(dx: -options.redactionPadding, dy: -options.redactionPadding)
                        redactionRectsPx.append(padded)
                    case .replace(let repl):
                        replacementRunsPx.append((rectPx, repl))
                        textRuns.append(RecognizedRun(kind: .replace(repl), rectInPixels: rectPx))
                    case .keep(let s):
                        textRuns.append(RecognizedRun(kind: .keep(s), rectInPixels: rectPx))
                    }
                }
            }
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
        if options.doOCR {
            for r in textRuns {
                let rectPt = CGRect(
                    x: pixelsToPoints(r.rectInPixels.origin.x, dpi: options.dpi),
                    y: pixelsToPoints(r.rectInPixels.origin.y, dpi: options.dpi),
                    width: pixelsToPoints(r.rectInPixels.width, dpi: options.dpi),
                    height: pixelsToPoints(r.rectInPixels.height, dpi: options.dpi)
                )
                runsInPoints.append(RecognizedRun(kind: r.kind, rectInPixels: rectPt))
            }
        }
        
        return PageProcessResult(pageSizePoints: mediaBox.size, cgImage: finalImage, textRunsInPoints: runsInPoints)
    }
    
    private func ruleReplacement(text: String, repl: String) -> String {
        return repl // basic: ignore capture groups; could extend.
    }
    
    private func recognizeText(cgImage: CGImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.minimumTextHeight = 0.01
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.customWords = [] // can be extended for domain terms
        request.recognitionLanguages = languages
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let results = request.results else { return [] }
        return results
    }
    
    private func writePDF(pages: [PageProcessResult], to url: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "PDFQuickFix", code: -7, userInfo: [NSLocalizedDescriptionKey: "Cannot create data consumer"])
        }
        var mediaBox = CGRect(origin: .zero, size: .zero)
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
