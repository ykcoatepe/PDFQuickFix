import Foundation
import PDFKit
import CoreGraphics

struct PDFRenderRequest: Hashable {
    enum Kind {
        case thumbnail
        // future: fullPage, zoomedRegion, etc.
    }

    let kind: Kind
    let pageIndex: Int
    /// "Scale bucket" so close scales share cache entries.
    let scaleBucket: Int
    let size: CGSize

    func hash(into hasher: inout Hasher) {
        hasher.combine(pageIndex)
        hasher.combine(scaleBucket)
        hasher.combine(kindHash)
    }

    private var kindHash: Int {
        switch kind {
        case .thumbnail: return 1
        }
    }

    static func == (lhs: PDFRenderRequest, rhs: PDFRenderRequest) -> Bool {
        lhs.kindHash == rhs.kindHash &&
        lhs.pageIndex == rhs.pageIndex &&
        lhs.scaleBucket == rhs.scaleBucket
    }
}

final class PDFRenderService {
    static let shared = PDFRenderService()

    private let queue: OperationQueue
    private let cache: NSCache<PDFRenderRequestBox, CGImage>
    private var operations: [PDFRenderRequest: Operation] = [:]
    private let lock = NSLock()

    private init() {
        queue = OperationQueue()
        queue.name = "com.pdfquickfix.render"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3

        cache = NSCache()
        cache.countLimit = 512
    }

    // Wrapper so NSCache can use the request as a key.
    private final class PDFRenderRequestBox: NSObject {
        let request: PDFRenderRequest

        init(_ request: PDFRenderRequest) { self.request = request }

        override var hash: Int { request.hashValue }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? PDFRenderRequestBox else { return false }
            return other.request == request
        }
    }

    func cachedImage(for request: PDFRenderRequest) -> CGImage? {
        cache.object(forKey: PDFRenderRequestBox(request))
    }

    func image(for request: PDFRenderRequest,
               documentURL: URL?,
               documentData: Data?,
               priority: Operation.QueuePriority = .normal,
               completion: @escaping (CGImage?) -> Void) {

        // Fast path: cache hit.
        if let cached = cachedImage(for: request) {
            completion(cached)
            return
        }

        // Cancel any older lower-priority operation for the same request.
        lock.lock()
        if let op = operations[request], !op.isCancelled {
            op.cancel()
            operations[request] = nil
        }

        let box = PDFRenderRequestBox(request)
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            let signpostID = PerfLog.begin("RenderThumbnail")
            let image = Self.renderThumbnail(request: request,
                                             url: documentURL,
                                             data: documentData)
            PerfLog.end("RenderThumbnail", signpostID)
            if let image {
                self.cache.setObject(image, forKey: box)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
        op.completionBlock = { [weak self, weak op] in
            guard let self, let op else { return }
            self.lock.lock()
            if let current = self.operations[request], current === op {
                self.operations[request] = nil
            }
            self.lock.unlock()
        }
        op.queuePriority = priority
        operations[request] = op
        lock.unlock()

        queue.addOperation(op)
    }

    func cancel(request: PDFRenderRequest) {
        lock.lock()
        let op = operations.removeValue(forKey: request)
        lock.unlock()
        op?.cancel()
    }

    func cancelAll() {
        lock.lock()
        operations.removeAll()
        lock.unlock()
        queue.cancelAllOperations()
    }

    struct DebugInfo {
        let queueOperationCount: Int
        let trackedOperationsCount: Int
    }

    func debugInfo() -> DebugInfo {
        lock.lock()
        let opCount = queue.operationCount
        let tracked = operations.count
        lock.unlock()
        return DebugInfo(queueOperationCount: opCount,
                         trackedOperationsCount: tracked)
    }
}

extension PDFRenderService {
    static func renderThumbnail(request: PDFRenderRequest,
                                url: URL?,
                                data: Data?) -> CGImage? {
        guard request.pageIndex >= 0 else { return nil }
        return renderThumbnail(pageIndex: request.pageIndex,
                               targetSize: request.size,
                               url: url,
                               data: data)
    }

    private static func renderThumbnail(pageIndex: Int,
                                        targetSize: CGSize,
                                        url: URL?,
                                        data: Data?) -> CGImage? {
        guard let page = makeCGPage(index: pageIndex, url: url, data: data) else { return nil }
        let mediaBox = page.getBoxRect(.mediaBox)
        let safeWidth = max(mediaBox.width, 1)
        let safeHeight = max(mediaBox.height, 1)
        let scale = min(targetSize.width / safeWidth, targetSize.height / safeHeight, 1)
        let width = max(Int(safeWidth * scale), 1)
        let height = max(Int(safeHeight * scale), 1)

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: mediaBox.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.drawPDFPage(page)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private static func makeCGPage(index: Int, url: URL?, data: Data?) -> CGPDFPage? {
        if let url,
           let provider = CGDataProvider(url: url as CFURL),
           let cgDoc = CGPDFDocument(provider),
           index < cgDoc.numberOfPages {
            return cgDoc.page(at: index + 1)
        }
        if let data,
           let provider = CGDataProvider(data: data as CFData),
           let cgDoc = CGPDFDocument(provider),
           index < cgDoc.numberOfPages {
            return cgDoc.page(at: index + 1)
        }
        return nil
    }
}
