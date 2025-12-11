import Foundation
import CoreGraphics
import PDFKit

/// A lightweight PDF loader that uses CGPDFDocument for fast page access without
/// loading the entire PDFDocument structure. This is optimized for massive documents
/// (7000+ pages) where we want to minimize memory usage and startup time.
///
/// Key optimizations:
/// - Uses CGPDFDocument which is more memory-efficient than PDFDocument
/// - Renders thumbnails directly from CGPDFPage without PDFKit overhead
/// - Lazy page resolution - only resolves PDFPage instances when needed for editing
/// - Keeps file open for streaming access rather than loading into memory
final class StreamingPDFLoader {
    
    // MARK: - Properties
    
    /// The underlying CGPDFDocument for lightweight page access
    private(set) var cgDocument: CGPDFDocument?
    
    /// The file URL being accessed
    private(set) var fileURL: URL?
    
    /// Total number of pages in the document
    var pageCount: Int {
        cgDocument?.numberOfPages ?? 0
    }
    
    /// Whether the loader has a document open
    var isOpen: Bool {
        cgDocument != nil
    }
    
    // MARK: - Page Resolution Cache
    
    /// Cache of resolved PDFPage instances (for editing operations)
    private var resolvedPages: [Int: PDFPage] = [:]
    private let resolutionLock = NSLock()
    private let maxResolvedPages = 50
    
    /// LRU order for eviction
    private var resolutionOrder: [Int] = []
    
    // MARK: - Initialization
    
    init() {}
    
    deinit {
        close()
    }
    
    // MARK: - Document Loading
    
    /// Open a PDF file for streaming access. This is very fast as it only parses
    /// the PDF header and cross-reference table, not the page content.
    func open(url: URL) -> Bool {
        close()
        
        guard let provider = CGDataProvider(url: url as CFURL),
              let document = CGPDFDocument(provider) else {
            return false
        }
        
        self.cgDocument = document
        self.fileURL = url
        return true
    }
    
    /// Close the document and release resources
    func close() {
        cgDocument = nil
        fileURL = nil
        resolutionLock.lock()
        resolvedPages.removeAll()
        resolutionOrder.removeAll()
        resolutionLock.unlock()
    }
    
    // MARK: - Page Access (CGPDFPage - Lightweight)
    
    /// Get a CGPDFPage for rendering. This is lightweight and suitable for thumbnails.
    func cgPage(at index: Int) -> CGPDFPage? {
        guard let doc = cgDocument else { return nil }
        // CGPDFDocument uses 1-based page indexing
        return doc.page(at: index + 1)
    }
    
    // MARK: - Thumbnail Rendering
    
    /// Render a thumbnail image for a specific page. This uses CGPDFDocument directly
    /// without going through PDFKit, which is faster for massive documents.
    func renderThumbnail(at index: Int, size: CGSize) -> CGImage? {
        guard let page = cgPage(at: index) else { return nil }
        
        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0 && mediaBox.height > 0 else { return nil }
        
        // Calculate scale to fit the target size while maintaining aspect ratio
        let scaleX = size.width / mediaBox.width
        let scaleY = size.height / mediaBox.height
        let scale = min(scaleX, scaleY)
        
        let width = Int(mediaBox.width * scale)
        let height = Int(mediaBox.height * scale)
        
        guard width > 0, height > 0 else { return nil }
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        // Fill with white background
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        // Transform to draw the PDF page
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        
        // PDF coordinate system has origin at bottom-left
        context.translateBy(x: 0, y: mediaBox.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -mediaBox.origin.x, y: -mediaBox.origin.y)
        
        context.drawPDFPage(page)
        context.restoreGState()
        
        return context.makeImage()
    }
    
    // MARK: - PDFPage Resolution (For Editing)
    
    /// Resolve a full PDFPage instance for editing operations. This is heavier
    /// than cgPage() but needed for annotation support.
    func resolvePage(at index: Int) -> PDFPage? {
        resolutionLock.lock()
        defer { resolutionLock.unlock() }
        
        // Check cache
        if let cached = resolvedPages[index] {
            // Move to end of LRU order
            if let orderIndex = resolutionOrder.firstIndex(of: index) {
                resolutionOrder.remove(at: orderIndex)
            }
            resolutionOrder.append(index)
            return cached
        }
        
        // Create PDFDocument on-demand for page resolution
        guard let url = fileURL,
              let pdfDoc = PDFDocument(url: url),
              let page = pdfDoc.page(at: index) else {
            return nil
        }
        
        // Cache the resolved page
        resolvedPages[index] = page
        resolutionOrder.append(index)
        
        // Evict oldest if over limit
        while resolutionOrder.count > maxResolvedPages {
            let oldest = resolutionOrder.removeFirst()
            resolvedPages.removeValue(forKey: oldest)
        }
        
        return page
    }
    
    /// Clear resolved page cache (call when memory pressure is detected)
    func evictResolvedPages() {
        resolutionLock.lock()
        resolvedPages.removeAll()
        resolutionOrder.removeAll()
        resolutionLock.unlock()
    }
    
    // MARK: - Page Info
    
    /// Get the media box size for a page without fully resolving it
    func pageSize(at index: Int) -> CGSize? {
        guard let page = cgPage(at: index) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        return CGSize(width: box.width, height: box.height)
    }
    
    /// Check if a page exists
    func hasPage(at index: Int) -> Bool {
        guard let doc = cgDocument else { return false }
        return index >= 0 && index < doc.numberOfPages
    }
}

// MARK: - Batch Operations

extension StreamingPDFLoader {
    
    /// Prefetch thumbnails for a range of pages in the background
    func prefetchThumbnails(
        range: Range<Int>,
        size: CGSize,
        completion: @escaping (Int, CGImage?) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            for index in range {
                let thumbnail = self.renderThumbnail(at: index, size: size)
                DispatchQueue.main.async {
                    completion(index, thumbnail)
                }
            }
        }
    }
    
    /// Get page count without loading the full document (static helper)
    static func quickPageCount(at url: URL) -> Int? {
        guard let provider = CGDataProvider(url: url as CFURL),
              let doc = CGPDFDocument(provider) else {
            return nil
        }
        return doc.numberOfPages
    }
}
