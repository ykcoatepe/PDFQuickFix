import Foundation

struct DocumentProfile {
    let isLarge: Bool
    let isMassive: Bool
    
    // Feature flags
    let searchEnabled: Bool
    let thumbnailsEnabled: Bool
    let outlineEnabled: Bool
    let studioEnabled: Bool
    let globalAnnotationsEnabled: Bool
    
    // Thresholds
    static let largePageThreshold = 1000
    static let massivePageThreshold = 3000
    
    static func from(pageCount: Int, fileSizeBytes: Int64? = nil) -> DocumentProfile {
        let isMassive = pageCount >= massivePageThreshold
        let isLarge = pageCount >= largePageThreshold
        
        return DocumentProfile(
            isLarge: isLarge,
            isMassive: isMassive,
            searchEnabled: !isMassive,
            thumbnailsEnabled: !isMassive,
            outlineEnabled: !isMassive, // Disable full outline tree for massive docs
            studioEnabled: !isMassive,
            globalAnnotationsEnabled: !isMassive
        )
    }
}
