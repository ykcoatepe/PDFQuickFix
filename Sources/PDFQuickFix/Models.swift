import Foundation

struct FindReplaceRule: Identifiable, Hashable {
    let id = UUID()
    var find: String
    var replace: String
}

struct RedactionPattern: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var regex: NSRegularExpression
    
    init(name: String, pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
        self.name = name
        self.regex = try! NSRegularExpression(pattern: pattern, options: options)
    }
}

struct QuickFixOptions {
    var doOCR: Bool = true
    var dpi: CGFloat = 300
    var redactionPadding: CGFloat = 2.0
}

struct DocumentProfile {
    let isLarge: Bool
    let isMassive: Bool
    
    // Feature flags
    let searchEnabled: Bool
    let thumbnailsEnabled: Bool
    let outlineEnabled: Bool
    let studioEnabled: Bool
    let globalAnnotationsEnabled: Bool
    
    // Thresholds (aligned with DocumentValidationRunner)
    private static var largePageThreshold: Int { DocumentValidationRunner.largeDocumentPageThreshold }
    private static var massivePageThreshold: Int { DocumentValidationRunner.massiveDocumentPageThreshold }
    private static let massiveFileSizeThreshold: Int64 = 200 * 1024 * 1024 // 200 MB
    
    static func from(pageCount: Int, fileSizeBytes: Int64? = nil) -> DocumentProfile {
        let isLarge = pageCount > largePageThreshold
        let isMassivePageCount = pageCount >= massivePageThreshold
        let isMassiveSize = (fileSizeBytes ?? 0) >= massiveFileSizeThreshold
        let isMassive = isMassivePageCount || isMassiveSize
        
        // In massive mode, we disable heavy features to prevent UI freezing
        return DocumentProfile(
            isLarge: isLarge,
            isMassive: isMassive,
            // Search is inexpensive; keep enabled to allow find-in-document even in massive mode
            searchEnabled: true,
            // Thumbnails stay enabled but should be low-res & lazy when massive
            thumbnailsEnabled: true,
            // Outline stays available but should be loaded lazily for massive docs
            outlineEnabled: true,
            // Keep Studio available; heavy paths must self-guard when massive
            studioEnabled: true,
            // Global annotation scanning is very expensive
            globalAnnotationsEnabled: !isMassive
        )
    }
    
    static let empty = DocumentProfile(
        isLarge: false,
        isMassive: false,
        searchEnabled: false,
        thumbnailsEnabled: false,
        outlineEnabled: false,
        studioEnabled: false,
        globalAnnotationsEnabled: false
    )
}
