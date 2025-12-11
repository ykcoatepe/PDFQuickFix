import Foundation
import PDFKit
import CoreGraphics
import AppKit

struct PDFRenderRequest: Hashable {
    enum Kind {
        case thumbnail
        case page
        // future: zoomedRegion, etc.
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
        hasher.combine(size.width)
        hasher.combine(size.height)
    }

    private var kindHash: Int {
        switch kind {
        case .thumbnail: return 1
        case .page: return 2
        }
    }

    static func == (lhs: PDFRenderRequest, rhs: PDFRenderRequest) -> Bool {
        lhs.kindHash == rhs.kindHash &&
        lhs.pageIndex == rhs.pageIndex &&
        lhs.scaleBucket == rhs.scaleBucket &&
        lhs.size == rhs.size
    }
}

final class PDFRenderService {
    static let shared = PDFRenderService()

    private let queue: OperationQueue
    private let cache: NSCache<PDFRenderRequestBox, CGImage>
    private var operations: [PDFRenderRequest: Operation] = [:]
    private let lock = NSLock()
    #if DEBUG
    /// Hook for tests/diagnostics to observe render requests (thumbnail throttling, etc.).
    var requestObserver: ((PDFRenderRequest) -> Void)?
    #endif

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

        #if DEBUG
        requestObserver?(request)
        #endif

        // Fast path: cache hit.
        if let cached = cachedImage(for: request) {
            let sp = PerfLog.begin("RenderCacheHit")
            PerfLog.end("RenderCacheHit", sp)
            #if DEBUG
            PerfMetrics.shared.recordThumbnailRequest()
            PerfMetrics.shared.recordThumbnailCacheHit()
            #endif
            completion(cached)
            return
        }

        #if DEBUG
        PerfMetrics.shared.recordThumbnailRequest()
        #endif

        // Cancel any older lower-priority operation for the same request.
        lock.lock()
        if let op = operations[request], !op.isCancelled {
            op.cancel()
            operations[request] = nil
        }

        let box = PDFRenderRequestBox(request)
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            let signpostID = PerfLog.begin("RenderImage")
            
            let image: CGImage?
            switch request.kind {
            case .thumbnail:
                image = Self.renderThumbnail(request: request, url: documentURL, data: documentData)
            case .page:
                image = Self.renderPageImage(request: request, url: documentURL, data: documentData)
            }
            
            PerfLog.end("RenderImage", signpostID)
            if let image {
                self.cache.setObject(image, forKey: box)
                #if DEBUG
                if request.kind == .thumbnail {
                    PerfMetrics.shared.recordThumbnailRender()
                }
                #endif
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

    /// Convenience for low-res thumbnails with a fixed bucket so cache hits are shared.
    func thumbnail(pageIndex: Int,
                   targetSize: CGSize,
                   documentURL: URL?,
                   documentData: Data?,
                   priority: Operation.QueuePriority = .normal,
                   completion: @escaping (CGImage?) -> Void) {
        let bucket = Self.thumbnailBucket(for: targetSize)
        let cappedSize = Self.thumbnailTargetSize(targetSize)
        let request = PDFRenderRequest(kind: .thumbnail,
                                       pageIndex: pageIndex,
                                       scaleBucket: bucket,
                                       size: cappedSize)
        image(for: request,
              documentURL: documentURL,
              documentData: documentData,
              priority: priority,
              completion: completion)
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
    
    /// Cancel all thumbnail requests for pages outside the specified window around center.
    /// This is useful for massive documents where rapid scrolling can queue many outdated requests.
    /// - Parameters:
    ///   - center: The current page index (center of the visible window)
    ///   - window: The number of pages on each side of center to keep (e.g., 25 means keep center±25)
    /// - Returns: Number of requests cancelled
    @discardableResult
    func cancelRequestsOutsideWindow(center: Int, window: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        var keysToCancel: [PDFRenderRequest] = []
        let keepRange = (center - window)...(center + window)
        
        // First pass: collect keys to cancel (don't mutate during iteration)
        for (request, _) in operations {
            guard case .thumbnail = request.kind else { continue }
            if !keepRange.contains(request.pageIndex) {
                keysToCancel.append(request)
            }
        }
        
        // Second pass: cancel and remove collected keys
        for request in keysToCancel {
            if let operation = operations.removeValue(forKey: request) {
                operation.cancel()
            }
        }
        
        return keysToCancel.count
    }
    
    /// Adjust priority of in-flight requests based on distance from center.
    /// Requests closer to center get higher priority.
    func reprioritizeRequests(center: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        for (request, operation) in operations {
            guard case .thumbnail = request.kind else { continue }
            
            let distance = abs(request.pageIndex - center)
            let priority: Operation.QueuePriority
            switch distance {
            case 0...5: priority = .veryHigh
            case 6...15: priority = .high
            case 16...30: priority = .normal
            default: priority = .low
            }
            operation.queuePriority = priority
        }
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
    private static func thumbnailBucket(for targetSize: CGSize) -> Int {
        // Bucket by (width * deviceScale) rounded to the nearest 10 to keep cache small.
        let scale = min(2.0, max(1.0, NSScreen.main?.backingScaleFactor ?? 1.0))
        let raw = Int((targetSize.width * scale).rounded())
        return (raw / 10) * 10 // coarse bucket
    }

    private static func thumbnailTargetSize(_ requested: CGSize) -> CGSize {
        // Don't scale here - renderThumbnail already applies deviceScale
        // This is just for capping/normalizing the size
        return requested
    }

    static func renderThumbnail(request: PDFRenderRequest,
                                url: URL?,
                                data: Data?) -> CGImage? {
        guard request.pageIndex >= 0 else { return nil }
        return renderThumbnail(pageIndex: request.pageIndex,
                               targetSize: request.size,
                               url: url,
                               data: data)
    }
    
    static func renderPageImage(request: PDFRenderRequest,
                                url: URL?,
                                data: Data?) -> CGImage? {
        guard request.pageIndex >= 0 else { return nil }
        return renderPage(pageIndex: request.pageIndex,
                          
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
        let deviceScale = min(2.0, max(1.0, NSScreen.main?.backingScaleFactor ?? 1.0))
        let target = CGSize(width: targetSize.width * deviceScale, height: targetSize.height * deviceScale)
        let scale = min(target.width / safeWidth, target.height / safeHeight, 1)
        let width = max(Int(safeWidth * scale), 1)
        let height = max(Int(safeHeight * scale), 1)

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
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
    
    private static func renderPage(pageIndex: Int,
                                   targetSize: CGSize,
                                   url: URL?,
                                   data: Data?) -> CGImage? {
        guard let page = makeCGPage(index: pageIndex, url: url, data: data) else { return nil }
        let mediaBox = page.getBoxRect(.mediaBox)
        let safeWidth = max(mediaBox.width, 1)
        let safeHeight = max(mediaBox.height, 1)
        
        // Calculate scale to fit targetSize while maintaining aspect ratio?
        // Or fill targetSize?
        // Usually for page rendering we want to match the target size exactly if passed,
        // or derive it from a scale factor.
        // In this context, 'targetSize' in the request is likely the desired output pixel size.
        
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        
        guard width > 0, height > 0 else { return nil }
        
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        
        ctx.interpolationQuality = .high
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        
        // Scale to fit
        let scaleX = CGFloat(width) / safeWidth
        let scaleY = CGFloat(height) / safeHeight
        // Use the smaller scale to fit entirely, or fill?
        // For a "render page image" we usually expect it to fill the requested size if the aspect ratio matches,
        // or we just scale content.
        // Let's assume the caller provided a size that matches the aspect ratio of the page * scale.
        
        ctx.saveGState()
        ctx.scaleBy(x: scaleX, y: scaleY)
        ctx.translateBy(x: 0, y: mediaBox.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -mediaBox.origin.x, y: -mediaBox.origin.y)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        
        return ctx.makeImage()
    }
}

final class RenderThrottle {
    private var workItem: DispatchWorkItem?
    
    /// Schedules a block to be executed after a delay, cancelling any pending execution.
    /// - Parameters:
    ///   - delay: The delay in seconds before execution. Default is 0.06s (approx 1 frame at 60fps).
    ///   - block: The block to execute on the main actor.
    func schedule(_ delay: TimeInterval = 0.06, _ block: @escaping @MainActor () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem {
            Task { @MainActor in block() }
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    
    /// Cancels any pending execution.
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
