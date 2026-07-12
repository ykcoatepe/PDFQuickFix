import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

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
        case .thumbnail: 1
        case .page: 2
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
    private let cache: NSCache<PDFRenderCacheKeyBox, CGImage>
    private var operations: [PDFRenderCacheKey: TrackedOperation] = [:]
    private let lock = NSLock()
    private var cancellationGeneration: UInt64 = 0
    #if DEBUG
        /// Hook for tests/diagnostics to observe render requests (thumbnail throttling, etc.).
        var requestObserver: ((PDFRenderRequest) -> Void)?
        var identityComputationHook: (() -> Void)?
        var renderExecutionHook: (() -> Void)?
    #endif

    private init() {
        queue = OperationQueue()
        queue.name = "com.pdfquickfix.render"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 3

        cache = NSCache()
        cache.countLimit = 512
    }

    /// Wrapper so NSCache can use the request as a key.
    private struct PDFRenderCacheKey: Hashable {
        let request: PDFRenderRequest
        let documentIdentity: String
    }

    private struct TrackedOperation {
        let operation: Operation
        let token: UUID
    }

    private final class PDFRenderCacheKeyBox: NSObject {
        let key: PDFRenderCacheKey

        init(_ key: PDFRenderCacheKey) {
            self.key = key
        }

        override var hash: Int {
            key.hashValue
        }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? PDFRenderCacheKeyBox else { return false }
            return other.key == key
        }
    }

    private func cachedImage(for key: PDFRenderCacheKey) -> CGImage? {
        cache.object(forKey: PDFRenderCacheKeyBox(key))
    }

    func image(for request: PDFRenderRequest,
               documentURL: URL?,
               documentData: Data?,
               documentIdentity: String? = nil,
               priority: Operation.QueuePriority = .normal,
               completion: @escaping (CGImage?) -> Void)
    {
        #if DEBUG
            requestObserver?(request)
        #endif

        lock.lock()
        let requestGeneration = cancellationGeneration
        lock.unlock()

        #if DEBUG
            if documentIdentity == nil {
                identityComputationHook?()
            }
        #endif

        let key = PDFRenderCacheKey(
            request: request,
            documentIdentity: documentIdentity ?? Self.documentIdentity(url: documentURL, data: documentData)
        )

        lock.lock()
        guard requestGeneration == cancellationGeneration else {
            lock.unlock()
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // Fast path: cache hit. Holding the lock orders lookup with cancelAll().
        if let cached = cachedImage(for: key) {
            lock.unlock()
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
        if let tracked = operations[key], !tracked.operation.isCancelled {
            tracked.operation.cancel()
            operations[key] = nil
        }

        let box = PDFRenderCacheKeyBox(key)
        let token = UUID()
        let op = BlockOperation { [weak self] in
            guard let self else { return }
            let signpostID = PerfLog.begin("RenderImage")

            #if DEBUG
                renderExecutionHook?()
            #endif

            let image: CGImage? = switch request.kind {
            case .thumbnail:
                Self.renderThumbnail(request: request, url: documentURL, data: documentData)
            case .page:
                Self.renderPageImage(request: request, url: documentURL, data: documentData)
            }

            PerfLog.end("RenderImage", signpostID)
            lock.lock()
            guard requestGeneration == cancellationGeneration,
                  operations[key]?.token == token
            else {
                lock.unlock()
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            if let image {
                cache.setObject(image, forKey: box)
                #if DEBUG
                    if request.kind == .thumbnail {
                        PerfMetrics.shared.recordThumbnailRender()
                    }
                #endif
            }
            lock.unlock()
            DispatchQueue.main.async {
                completion(image)
            }
        }
        op.completionBlock = { [weak self, weak op] in
            guard let self, let op else { return }
            lock.lock()
            if let current = operations[key], current.operation === op {
                operations[key] = nil
            }
            lock.unlock()
        }
        op.queuePriority = priority
        operations[key] = TrackedOperation(operation: op, token: token)
        lock.unlock()

        queue.addOperation(op)
    }

    /// Convenience for low-res thumbnails with a fixed bucket so cache hits are shared.
    func thumbnail(pageIndex: Int,
                   targetSize: CGSize,
                   documentURL: URL?,
                   documentData: Data?,
                   documentIdentity: String? = nil,
                   priority: Operation.QueuePriority = .normal,
                   completion: @escaping (CGImage?) -> Void)
    {
        let bucket = Self.thumbnailBucket(for: targetSize)
        let cappedSize = Self.thumbnailTargetSize(targetSize)
        let request = PDFRenderRequest(kind: .thumbnail,
                                       pageIndex: pageIndex,
                                       scaleBucket: bucket,
                                       size: cappedSize)
        image(for: request,
              documentURL: documentURL,
              documentData: documentData,
              documentIdentity: documentIdentity,
              priority: priority,
              completion: completion)
    }

    func cancel(request: PDFRenderRequest) {
        lock.lock()
        let matchingKeys = operations.keys.filter { $0.request == request }
        let matchingOperations = matchingKeys.compactMap { operations.removeValue(forKey: $0)?.operation }
        lock.unlock()
        matchingOperations.forEach { $0.cancel() }
    }

    func cancelAll() {
        lock.lock()
        cancellationGeneration &+= 1
        operations.removeAll()
        cache.removeAllObjects()
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
        let keepRange = (center - window) ... (center + window)

        // First pass: collect keys to cancel (don't mutate during iteration)
        for (key, _) in operations {
            let request = key.request
            guard case .thumbnail = request.kind else { continue }
            if !keepRange.contains(request.pageIndex) {
                keysToCancel.append(request)
            }
        }

        // Second pass: cancel and remove collected keys
        for request in keysToCancel {
            let keys = operations.keys.filter { $0.request == request }
            for key in keys {
                operations.removeValue(forKey: key)?.operation.cancel()
            }
        }

        return keysToCancel.count
    }

    /// Adjust priority of in-flight requests based on distance from center.
    /// Requests closer to center get higher priority.
    func reprioritizeRequests(center: Int) {
        lock.lock()
        defer { lock.unlock() }

        for (key, tracked) in operations {
            let request = key.request
            guard case .thumbnail = request.kind else { continue }

            let distance = abs(request.pageIndex - center)
            let priority: Operation.QueuePriority = switch distance {
            case 0 ... 5: .veryHigh
            case 6 ... 15: .high
            case 16 ... 30: .normal
            default: .low
            }
            tracked.operation.queuePriority = priority
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

    private static func documentIdentity(url: URL?, data: Data?) -> String {
        if let url {
            var identity = Data(url.standardizedFileURL.path.utf8)
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
                identity.append(Data("|\(values.fileSize ?? -1)|\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)".utf8))
            }
            return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        }
        guard let data else { return "no-document" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        requested
    }

    static func renderThumbnail(request: PDFRenderRequest,
                                url: URL?,
                                data: Data?) -> CGImage?
    {
        guard request.pageIndex >= 0 else { return nil }
        return renderThumbnail(pageIndex: request.pageIndex,
                               targetSize: request.size,
                               url: url,
                               data: data)
    }

    static func renderPageImage(request: PDFRenderRequest,
                                url: URL?,
                                data: Data?) -> CGImage?
    {
        guard request.pageIndex >= 0 else { return nil }
        return renderPage(pageIndex: request.pageIndex,

                          targetSize: request.size,
                          url: url,
                          data: data)
    }

    private static func renderThumbnail(pageIndex: Int,
                                        targetSize: CGSize,
                                        url: URL?,
                                        data: Data?) -> CGImage?
    {
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
           index < cgDoc.numberOfPages
        {
            return cgDoc.page(at: index + 1)
        }
        if let data,
           let provider = CGDataProvider(data: data as CFData),
           let cgDoc = CGPDFDocument(provider),
           index < cgDoc.numberOfPages
        {
            return cgDoc.page(at: index + 1)
        }
        return nil
    }

    private static func renderPage(pageIndex: Int,
                                   targetSize: CGSize,
                                   url: URL?,
                                   data: Data?) -> CGImage?
    {
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
