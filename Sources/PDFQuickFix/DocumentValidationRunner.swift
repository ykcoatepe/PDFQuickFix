import Foundation
import PDFKit

final class DocumentValidationRunner: ObservableObject {
    private enum Kind: Hashable {
        case open
        case validation
    }

    private struct ActiveJob {
        let token: UUID
        let job: PDFDocumentSanitizer.Job
        let url: URL
    }

    private var jobs: [Kind: ActiveJob] = [:]

    @discardableResult
    func openDocument(at url: URL,
                      progress: ((Int, Int) -> Void)? = nil,
                      completion: @escaping (Result<PDFDocument, Error>) -> Void) -> UUID {
        start(kind: .open, url: url, options: .quickOpen, progress: progress, completion: completion)
    }

    @discardableResult
    func validateDocument(at url: URL,
                          pageLimit: Int?,
                          progress: ((Int, Int) -> Void)? = nil,
                          completion: @escaping (Result<PDFDocument, Error>) -> Void) -> UUID {
        let options = PDFDocumentSanitizer.Options(validationPageLimit: pageLimit)
        return start(kind: .validation, url: url, options: options, progress: progress, completion: completion)
    }

    func cancelOpen() {
        cancel(kind: .open)
    }

    func cancelValidation() {
        cancel(kind: .validation)
    }

    func cancelAll() {
        cancelOpen()
        cancelValidation()
    }

    @discardableResult
    private func start(kind: Kind,
                       url: URL,
                       options: PDFDocumentSanitizer.Options,
                       progress: ((Int, Int) -> Void)? = nil,
                       completion: @escaping (Result<PDFDocument, Error>) -> Void) -> UUID {
        cancel(kind: kind)
        let token = UUID()
        let job = PDFDocumentSanitizer.loadDocumentAsync(at: url,
                                                         options: options,
                                                         progress: { [weak self] processed, total in
                                                             guard let self else { return }
                                                             guard self.isActive(token: token, kind: kind, url: url) else { return }
                                                             progress?(processed, total)
                                                         },
                                                         completion: { [weak self] result in
                                                             guard let self else { return }
                                                             guard self.isActive(token: token, kind: kind, url: url) else { return }
                                                             self.jobs[kind] = nil
                                                             completion(result)
                                                         })
        jobs[kind] = ActiveJob(token: token, job: job, url: url)
        return token
    }

    private func cancel(kind: Kind) {
        if let job = jobs.removeValue(forKey: kind) {
            job.job.cancel()
        }
    }

    private func isActive(token: UUID, kind: Kind, url: URL) -> Bool {
        guard let context = jobs[kind] else { return false }
        return context.token == token && context.url == url
    }
}
