import Foundation
import SwiftUI

/// A virtualized page snapshot provider that only materializes entries for visible + buffer pages.
/// This dramatically reduces memory usage for massive documents (7000+ pages).
@MainActor
final class VirtualPageProvider: ObservableObject {
    
    // MARK: - Configuration
    
    /// Number of snapshots to keep materialized around the current position
    nonisolated static let defaultWindowSize = 200
    
    /// Threshold below which we use the standard full array approach
    nonisolated static let virtualizationThreshold = 2000
    
    // MARK: - Published State
    
    /// The total number of pages in the document
    @Published private(set) var totalCount: Int = 0
    
    /// Whether virtualization is active (true for massive docs)
    @Published private(set) var isVirtualized: Bool = false
    
    /// The currently materialized snapshots (subset for virtualized, full array otherwise)
    @Published private(set) var visibleSnapshots: [PageSnapshot] = []
    
    /// Range of pages currently materialized
    @Published private(set) var materializedRange: Range<Int> = 0..<0
    
    // MARK: - Private State
    
    private var cache: [Int: PageSnapshot] = [:]
    private var thumbnailCache: NSCache<NSNumber, CGImage>
    private let windowSize: Int
    private var centerIndex: Int = 0
    
    // MARK: - Initialization
    
    init(thumbnailCache: NSCache<NSNumber, CGImage>, windowSize: Int = VirtualPageProvider.defaultWindowSize) {
        self.thumbnailCache = thumbnailCache
        self.windowSize = windowSize
    }
    
    // MARK: - Public API
    
    /// Configure the provider with a new page count. Call when document changes.
    func configure(pageCount: Int, forceVirtualize: Bool = false) {
        totalCount = pageCount
        isVirtualized = forceVirtualize || pageCount >= Self.virtualizationThreshold
        cache.removeAll()
        centerIndex = 0
        
        if isVirtualized {
            // Start with a window around page 0
            updateMaterializedRange(around: 0)
        } else {
            // For smaller documents, materialize all pages upfront (existing behavior)
            materializeAll()
        }
    }
    
    /// Update the visible window when the user scrolls to a new center page.
    func updateCenter(_ newCenter: Int) {
        guard isVirtualized else { return }
        guard newCenter != centerIndex else { return }
        centerIndex = newCenter
        updateMaterializedRange(around: newCenter)
    }
    
    /// Get or create a snapshot for a specific index. Returns nil if out of bounds.
    func snapshot(at index: Int) -> PageSnapshot? {
        guard index >= 0 && index < totalCount else { return nil }
        
        if let cached = cache[index] {
            return cached
        }
        
        // Create a new placeholder snapshot
        let snapshot = makeSnapshot(at: index)
        cache[index] = snapshot
        return snapshot
    }
    
    /// Update the thumbnail for a specific page index.
    func updateThumbnail(at index: Int, thumbnail: CGImage) {
        guard index >= 0 && index < totalCount else { return }
        
        let existing = cache[index] ?? makeSnapshot(at: index)
        let updated = PageSnapshot(
            id: existing.id,
            index: existing.index,
            thumbnail: thumbnail,
            label: existing.label
        )
        cache[index] = updated
        
        // Update visible snapshots if this index is in the materialized range
        if materializedRange.contains(index) {
            rebuildVisibleSnapshots()
        }
    }
    
    /// Clear all cached data. Call when document is closed.
    func reset() {
        totalCount = 0
        isVirtualized = false
        cache.removeAll()
        visibleSnapshots = []
        materializedRange = 0..<0
        centerIndex = 0
    }
    
    /// Force a refresh of the visible snapshots (e.g., after external thumbnail cache update)
    func refreshVisibleSnapshots() {
        if isVirtualized {
            rebuildVisibleSnapshots()
        } else {
            materializeAll()
        }
    }
    
    // MARK: - Private Helpers
    
    private func makeSnapshot(at index: Int) -> PageSnapshot {
        let thumbnail = thumbnailCache.object(forKey: NSNumber(value: index))
        return PageSnapshot(
            id: index,
            index: index,
            thumbnail: thumbnail,
            label: "Page \(index + 1)"
        )
    }
    
    private func materializeAll() {
        cache.removeAll()
        visibleSnapshots = (0..<totalCount).map { index in
            let snapshot = makeSnapshot(at: index)
            cache[index] = snapshot
            return snapshot
        }
        materializedRange = 0..<totalCount
    }
    
    private func updateMaterializedRange(around center: Int) {
        let halfWindow = windowSize / 2
        let start = max(0, center - halfWindow)
        let end = min(totalCount, center + halfWindow)
        let newRange = start..<end
        
        // Evict snapshots outside the new range
        if materializedRange != newRange {
            let indicesToEvict = Set(materializedRange).subtracting(Set(newRange))
            for index in indicesToEvict {
                cache.removeValue(forKey: index)
            }
        }
        
        materializedRange = newRange
        rebuildVisibleSnapshots()
    }
    
    private func rebuildVisibleSnapshots() {
        visibleSnapshots = materializedRange.map { index in
            if let cached = cache[index] {
                return cached
            }
            let snapshot = makeSnapshot(at: index)
            cache[index] = snapshot
            return snapshot
        }
    }
}

// MARK: - Page Indices for Navigation

extension VirtualPageProvider {
    /// Returns all page indices (for jump-to-page navigation)
    var allPageIndices: [Int] {
        Array(0..<totalCount)
    }
    
    /// Returns whether a given index is currently materialized
    func isMaterialized(_ index: Int) -> Bool {
        materializedRange.contains(index)
    }
    
    /// Returns the distance from the center for a given index
    func distanceFromCenter(_ index: Int) -> Int {
        abs(index - centerIndex)
    }
}
