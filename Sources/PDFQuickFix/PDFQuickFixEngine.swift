import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import PDFQuickFixKit
import Vision

typealias QuickFixCancellationChecker = () -> Bool

enum PDFQuickFixEngineError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "Operation cancelled."
        }
    }
}

final class PDFQuickFixEngine {
    let options: QuickFixOptions
    let languages: [String]
    let queue = DispatchQueue(label: "pdfquickfix.engine", qos: .userInitiated)
    private let localOCRProviderOverride: LocalOCRProviding?
    private let cloudOCRProviderOverride: CloudOCRProviding?
    private let repairSourceURL: (URL) throws -> URL
    private let localOCRTimeout: TimeInterval = 12
    private let cloudOCRTimeout: TimeInterval = 20

    init(options: QuickFixOptions = .init(),
         languages: [String] = ["tr-TR", "en-US"],
         localOCRProvider: LocalOCRProviding? = nil,
         cloudOCRProvider: CloudOCRProviding? = nil,
         repairSourceURL: ((URL) throws -> URL)? = nil)
    {
        self.options = options
        self.languages = languages
        localOCRProviderOverride = localOCRProvider
        cloudOCRProviderOverride = cloudOCRProvider
        self.repairSourceURL = repairSourceURL ?? { try PDFRepairService().repairIfNeeded(inputURL: $0) }
    }

    func processResult(inputURL: URL,
                       outputURL: URL? = nil,
                       isTemporaryOutput: Bool? = nil,
                       redactionPatterns: [RedactionPattern] = DefaultPatterns.defaults(),
                       customRegexes: [NSRegularExpression] = [],
                       findReplace: [FindReplaceRule] = [],
                       manualRedactions: [Int: [CGRect]] = [:],
                       shouldCancel: QuickFixCancellationChecker? = nil,
                       progress: ((Int, Int) -> Void)? = nil) throws -> QuickFixResult
    {
        try checkCancellation(shouldCancel)

        let repairedURL: URL
        let doc: PDFDocument
        do {
            // Repair/Pre-process
            repairedURL = try repairSourceURL(inputURL)

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
        var redactedTextCandidates: [String] = []
        let localOCRProvider = options.ocrProvider == .autoLocalOCR
            ? (localOCRProviderOverride ?? selectLocalOCRProvider(preferredModel: options.localOCRModel))
            : nil
        let trimmedCloudKey = options.cloudOcrApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cloudOCRProvider = (options.cloudOcrEnabled && !trimmedCloudKey.isEmpty)
            ? (cloudOCRProviderOverride ?? GoogleVisionOCRProvider(apiKey: trimmedCloudKey, languages: languages))
            : nil

        for i in 0 ..< pageCount {
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
            if result.localOCREligible, !result.localOCRSucceeded {
                localOCRFallbackCount += 1
            }
            redactedTextCandidates.append(contentsOf: result.redactedTextCandidates)

            processedPages.append(result)
            progress?(i + 1, pageCount)
        }

        try checkCancellation(shouldCancel)
        let stagedURL = outURL.deletingLastPathComponent()
            .appendingPathComponent(".quickfix-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: stagedURL) }
        try writePDF(pages: processedPages, to: stagedURL)

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
        guard let outputDocument = PDFDocument(url: stagedURL) else {
            throw CleanupEvidenceError.unreadablePDF(fileName: outURL.lastPathComponent)
        }
        let comparison = try CleanupComparisonEngine().compare(
            source: doc,
            output: outputDocument,
            isCancelled: { shouldCancel?() == true }
        )
        let redactionVerification: CleanupRedactionVerification = if totalRedactionRectCount == 0 {
            CleanupEvidenceGenerator.verifyRedactions(
                candidates: [],
                outputExtractedText: outputDocument.string ?? ""
            )
        } else if redactedTextCandidates.isEmpty {
            CleanupRedactionVerification(
                status: .reviewRequired,
                checkedCandidateCount: 0,
                detectedCandidateCount: 0
            )
        } else {
            CleanupEvidenceGenerator.verifyRedactions(
                candidates: redactedTextCandidates,
                outputExtractedText: outputDocument.string ?? ""
            )
        }
        var evidenceWarnings: [String] = []
        if comparison.sourcePageCount != comparison.outputPageCount {
            evidenceWarnings.append("Source and output page counts differ.")
        }
        if emptyOCRPages > 0 {
            evidenceWarnings.append("One or more pages produced no OCR text.")
        }
        if redactionVerification.status == .reviewRequired {
            evidenceWarnings.append("Redaction verification requires manual review.")
        }
        let evidenceVerdict: CleanupEvidenceVerdict = if comparison.sourcePageCount != comparison.outputPageCount {
            .failed
        } else if evidenceWarnings.isEmpty {
            .passed
        } else {
            .reviewRequired
        }
        var evidence = try CleanupEvidenceGenerator.generate(
            sourceURL: repairedURL,
            outputURL: stagedURL,
            quickFixTelemetry: CleanupQuickFixTelemetry(
                redactionRectangleCount: totalRedactionRectCount,
                suppressedOCRRunCount: suppressedOCRRunCount,
                localOCRPageCount: localOCRPages,
                cloudOCRPageCount: cloudOCRPages,
                visionOCRPageCount: visionOCRPages,
                ocrDisabledPageCount: ocrDisabledPages,
                emptyOCRPageCount: emptyOCRPages,
                localOCRFallbackCount: localOCRFallbackCount
            ),
            comparison: comparison.evidenceSummary,
            redactionVerification: redactionVerification,
            verdict: evidenceVerdict,
            warnings: evidenceWarnings
        )
        let usesRepairedSource = repairedURL.standardizedFileURL != inputURL.standardizedFileURL
        if usesRepairedSource {
            let repairedDisplayName = inputURL.deletingPathExtension().lastPathComponent + "-repaired.pdf"
            evidence = evidence.replacingSourceFileName(with: repairedDisplayName)
        }
        evidence = evidence.replacingOutputFileName(with: outURL.lastPathComponent)
        // The destination changes only after reopening, comparison and evidence succeed.
        try checkCancellation(shouldCancel)
        try Data(contentsOf: stagedURL).write(to: outURL, options: .atomic)
        return QuickFixResult(
            outputURL: outURL,
            isTemporaryOutput: isTemporaryOutput ?? (outputURL == nil),
            previewPageIndex: pagesWithRedactions.first ?? emptyOCRPageIndices.first,
            redactionReport: report,
            ocrReport: ocrReport,
            sourceURL: repairedURL,
            isTemporarySource: usesRepairedSource,
            cleanupEvidence: evidence,
            cleanupComparison: comparison
        )
    }

    func process(inputURL: URL,
                 outputURL: URL? = nil,
                 isTemporaryOutput: Bool? = nil,
                 redactionPatterns: [RedactionPattern] = DefaultPatterns.defaults(),
                 customRegexes: [NSRegularExpression] = [],
                 findReplace: [FindReplaceRule] = [],
                 manualRedactions: [Int: [CGRect]] = [:],
                 shouldCancel: QuickFixCancellationChecker? = nil,
                 progress: ((Int, Int) -> Void)? = nil) throws -> URL
    {
        try processResult(inputURL: inputURL,
                          outputURL: outputURL,
                          isTemporaryOutput: isTemporaryOutput,
                          redactionPatterns: redactionPatterns,
                          customRegexes: customRegexes,
                          findReplace: findReplace,
                          manualRedactions: manualRedactions,
                          shouldCancel: shouldCancel,
                          progress: progress).outputURL
    }

    private func processPage(page: PDFPage,
                             pageIndex _: Int,
                             manualRedactions: [CGRect],
                             redactionPatterns: [RedactionPattern],
                             customRegexes: [NSRegularExpression],
                             findReplace: [FindReplaceRule],
                             localOCRProvider: LocalOCRProviding?,
                             cloudOCRProvider: CloudOCRProviding?,
                             visionProvider: VisionOCRProvider) throws -> PageProcessResult
    {
        guard page.pageRef != nil else {
            throw NSError(domain: "PDFQuickFix", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing CGPDFPage"])
        }
        let geometry = PDFPageGeometry(page: page)
        let pageSize = geometry.size
        let widthPx = max(1, Int(pointsToPixels(pageSize.width, dpi: options.dpi).rounded(.up)))
        let heightPx = max(1, Int(pointsToPixels(pageSize.height, dpi: options.dpi).rounded(.up)))

        // Render original page into bitmap
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: widthPx, height: heightPx,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw NSError(domain: "PDFQuickFix", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap context"])
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
        try geometry.draw(page, in: ctx, target: CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

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
        let allRegexes = redactionPatterns.map(\.regex) + customRegexes

        let scaleX = CGFloat(widthPx) / pageSize.width
        let scaleY = CGFloat(heightPx) / pageSize.height
        var redactionRectsPx: [CGRect] = []
        var replacementRunsPx: [(rect: CGRect, replacement: String)] = []
        var visionTextRuns: [RecognizedRun] = []
        var suppressedOCRRunsByRedactionMatches = 0
        var didApplyVision = false
        var redactedTextCandidates: [String] = []

        for rect in manualRedactions {
            let visible = geometry.displayRect(for: rect)
            redactionRectsPx.append(CGRect(x: visible.minX * scaleX, y: visible.minY * scaleY,
                                          width: visible.width * scaleX, height: visible.height * scaleY))
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
                        if let r = m?.range {
                            redactionRanges.append(r)
                        }
                    }
                }
                redactedTextCandidates.append(contentsOf: Self.matchedRedactionCandidates(in: text, regexes: allRegexes))
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

                // Redaction wins every overlap, regardless of rule order or match length.
                let ranges = redactionRanges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
                var merged: [NSRange] = []
                for range in ranges {
                    if let last = merged.last, NSMaxRange(last) >= range.location {
                        merged[merged.count - 1] = NSUnionRange(last, range)
                    } else { merged.append(range) }
                }
                var special: [(start: Int, end: Int, kind: RecognizedRun.Kind)] = merged.map {
                    ($0.location, NSMaxRange($0), .skip)
                }
                var acceptedReplacements: [NSRange] = []
                for replacement in replacements where replacement.range.length > 0 {
                    let range = replacement.range
                    guard !merged.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                          !acceptedReplacements.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                    acceptedReplacements.append(range)
                    special.append((range.location, NSMaxRange(range), .replace(replacement.replacement)))
                }
                special.sort { $0.start < $1.start }
                var cursor = 0
                var segments: [(start: Int, end: Int, kind: RecognizedRun.Kind)] = []
                for edit in special {
                    if cursor < edit.start {
                        segments.append((cursor, edit.start, .keep(substring(forRange: NSRange(location: cursor, length: edit.start - cursor), in: text))))
                    }
                    segments.append(edit)
                    cursor = edit.end
                }
                if cursor < textLength {
                    segments.append((cursor, textLength, .keep(substring(forRange: NSRange(location: cursor, length: textLength - cursor), in: text))))
                }

                // Convert segments to runs with rectangles
                for seg in segments {
                    let r = NSRange(location: seg.start, length: seg.end - seg.start)
                    if let range = Range(r, in: text), let box = try? best.boundingBox(for: range) {
                        let rectPx = visionRectToPixelRect(box.boundingBox,
                                                           imageSize: CGSize(width: baseImage.width, height: baseImage.height))
                        switch seg.kind {
                        case .skip:
                            let padded = rectPx.insetBy(dx: -options.redactionPadding, dy: -options.redactionPadding)
                            redactionRectsPx.append(padded)
                            if options.doOCR {
                                suppressedOCRRunsByRedactionMatches += 1
                            }
                        case let .replace(repl):
                            replacementRunsPx.append((rectPx, repl))
                            visionTextRuns.append(RecognizedRun(kind: .replace(repl), rectInPixels: rectPx))
                        case let .keep(s):
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
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw NSError(domain: "PDFQuickFix", code: -5, userInfo: [NSLocalizedDescriptionKey: "Unable to create edit context"])
        }
        editCtx.interpolationQuality = .high
        // original
        editCtx.draw(baseImage, in: CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

        // A geometric overlap (including manual redactions) also suppresses a replacement.
        for run in replacementRunsPx where !redactionRectsPx.contains(where: { $0.intersects(run.rect) }) {
            editCtx.setFillColor(NSColor.white.cgColor)
            editCtx.fill(run.rect)
            PDFTextAppearance.draw(run.replacement, in: run.rect,
                                   font: .systemFont(ofSize: max(1, run.rect.height * 0.85)),
                                   color: .black, context: editCtx)
        }
        // Draw last as a second defense against any overlapping visible edit.
        editCtx.setFillColor(NSColor.black.cgColor)
        for rect in redactionRectsPx { editCtx.fill(rect) }

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
               let localRuns = runLocalOCROverlay(provider: provider, image: baseImage)
            {
                overlayRuns = quartzRuns(fromTopLeftRuns: localRuns, image: baseImage)
                localSucceeded = true
                ocrSource = .localOCR
            } else {
                if allowLocalOverlay, let cloudProvider = cloudOCRProvider,
                   let cloudRuns = runCloudOCROverlay(provider: cloudProvider, image: baseImage)
                {
                    overlayRuns = quartzRuns(fromTopLeftRuns: cloudRuns, image: baseImage)
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
                    x: r.rectInPixels.origin.x / scaleX,
                    y: r.rectInPixels.origin.y / scaleY,
                    width: r.rectInPixels.width / scaleX,
                    height: r.rectInPixels.height / scaleY
                )
                runsInPoints.append(RecognizedRun(kind: r.kind, rectInPixels: rectPt))
            }
            suppressedOCRRunsByRedactionMatches += suppressedByOverlap
        }

        return PageProcessResult(pageSizePoints: pageSize,
                                 cgImage: finalImage,
                                 textRunsInPoints: runsInPoints,
                                 redactionRectCount: redactionRectsPx.count,
                                 suppressedOCRRunCount: options.doOCR ? suppressedOCRRunsByRedactionMatches : 0,
                                 ocrSource: ocrSource,
                                 ocrRunCount: overlayRuns.count,
                                 localOCREligible: localEligible,
                                 localOCRSucceeded: localSucceeded,
                                 redactedTextCandidates: redactedTextCandidates)
    }

    static func matchedRedactionCandidates(in text: String,
                                           regexes: [NSRegularExpression]) -> [String]
    {
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        return regexes.flatMap { regex in
            regex.matches(in: text, range: fullRange).compactMap { match in
                guard match.range.length > 0,
                      let range = Range(match.range, in: text)
                else {
                    return nil
                }
                return String(text[range])
            }
        }
    }

    private func ruleReplacement(text _: String, repl: String) -> String {
        repl // basic: ignore capture groups; could extend.
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

    private func quartzRuns(fromTopLeftRuns runs: [RecognizedRun], image: CGImage) -> [RecognizedRun] {
        let size = CGSize(width: image.width, height: image.height)
        return runs.map {
            RecognizedRun(kind: $0.kind, rectInPixels: topLeftPixelRectToQuartzRect($0.rectInPixels, imageSize: size))
        }
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
                case let .keep(s): text = s
                case let .replace(s): text = s
                case .skip: continue
                }
                if text.isEmpty {
                    continue
                }

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
