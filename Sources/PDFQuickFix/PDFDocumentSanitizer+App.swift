import Foundation
import PDFKit
import PDFQuickFixKit

extension PDFDocumentSanitizer {
    public final class Job {
        private let lock = NSLock()
        private var _isCancelled = false

        public var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return _isCancelled
        }

        public func cancel() {
            lock.lock(); defer { lock.unlock() }
            _isCancelled = true
        }
        
        public init() {}
    }

    // Async helpers
    // Note: Re-implementing high level async flow here for the App module
    private static let sanitizerQueue = DispatchQueue(label: "com.pdfquickfix.sanitizer", qos: .userInitiated)

    public static func loadDocument(at url: URL,
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
    public static func loadDocumentAsync(at url: URL,
                                         options: Options = .full, // Changed default to verify
                                         progress: ProgressHandler? = nil,
                                         completion: @escaping (Result<PDFDocument, Error>) -> Void) -> Job {
        let job = Job()
        sanitizerQueue.async {
            let sp = PerfLog.begin("SanitizerOpen")
            defer { PerfLog.end("SanitizerOpen", sp) }
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

    private static func dispatchToMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

extension PDFDocumentSanitizer.Options {
    public static func quickOpen(limit: Int = 10) -> PDFDocumentSanitizer.Options {
        PDFDocumentSanitizer.Options(rebuildMode: .never,
                                     validationPageLimit: limit,
                                     sanitizeAnnotations: false,
                                     sanitizeOutline: false)
    }
}
