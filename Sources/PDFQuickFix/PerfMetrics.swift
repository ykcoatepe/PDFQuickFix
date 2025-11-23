#if DEBUG
import Foundation

final class PerfMetrics {
    static let shared = PerfMetrics()

    private let lock = NSLock()

    private(set) var thumbnailRequests: Int = 0
    private(set) var thumbnailRenders: Int = 0
    private(set) var thumbnailCacheHits: Int = 0

    private(set) var readerOpenDurations: [TimeInterval] = []
    private(set) var studioOpenDurations: [TimeInterval] = []

    private init() {}

    func reset() {
        lock.lock()
        thumbnailRequests = 0
        thumbnailRenders = 0
        thumbnailCacheHits = 0
        readerOpenDurations.removeAll()
        studioOpenDurations.removeAll()
        lock.unlock()
    }

    func recordThumbnailRequest() {
        lock.lock(); thumbnailRequests += 1; lock.unlock()
    }

    func recordThumbnailRender() {
        lock.lock(); thumbnailRenders += 1; lock.unlock()
    }

    func recordThumbnailCacheHit() {
        lock.lock(); thumbnailCacheHits += 1; lock.unlock()
    }

    func recordReaderOpen(duration: TimeInterval) {
        lock.lock(); readerOpenDurations.append(duration); lock.unlock()
    }

    func recordStudioOpen(duration: TimeInterval) {
        lock.lock(); studioOpenDurations.append(duration); lock.unlock()
    }

    func summaryString() -> String {
        lock.lock()
        defer { lock.unlock() }

        func avg(_ values: [TimeInterval]) -> TimeInterval {
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }

        let readerAvg = avg(readerOpenDurations)
        let studioAvg = avg(studioOpenDurations)

        return """
        [PerfMetrics]
        thumbnails requested: \(thumbnailRequests)
        thumbnails rendered:  \(thumbnailRenders)
        thumbnail cache hits: \(thumbnailCacheHits)
        reader open avg:      \(readerAvg * 1000.0) ms (\(readerOpenDurations.count) samples)
        studio open avg:      \(studioAvg * 1000.0) ms (\(studioOpenDurations.count) samples)
        """
    }
}
#endif
