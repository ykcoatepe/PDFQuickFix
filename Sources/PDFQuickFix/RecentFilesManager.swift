import Foundation

struct RecentFile: Identifiable, Codable {
    var id: UUID = UUID()
    // Stored bookmark data instead of raw URL for persistent access
    let bookmark: Data
    // We store display name because resolving bookmark might fail or be heavy just for a list
    let displayName: String
    let date: Date
    let pageCount: Int
    
    // Computed property for legacy support or UI convenience, though not directly usable for IO without resolve
    // We'll keep this as a hint, but the source of truth is the bookmark.
    // NOTE: This URL might be stale or inaccessible until resolved.
    var urlHint: URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    
    // Legacy name property
    var name: String {
        displayName
    }
}

class RecentFilesManager: ObservableObject {
    static let shared = RecentFilesManager()
    
    @Published var recentFiles: [RecentFile] = []
    
    private let maxRecentFiles = 10
    private let storageKey = "PDFQuickFix_RecentFiles"
    private let bookmarking: Bookmarking
    private let defaults: UserDefaults
    
    // Init allowing injection
    init(bookmarking: Bookmarking = SystemBookmarking(), defaults: UserDefaults = .standard) {
        self.bookmarking = bookmarking
        self.defaults = defaults
        load()
    }
    
    /// Adds a file to recents. Creates a security-scoped bookmark.
    /// - Parameters:
    ///   - url: The URL to add. MUST be a security-scoped URL (e.g. from Open Panel), or standard file URL.
    ///   - pageCount: Metadata for the file.
    func add(url: URL, pageCount: Int) {
        do {
            // Create bookmark
            let data = try bookmarking.bookmarkData(for: url, includingResourceValuesForKeys: nil, relativeTo: nil)
            
            // Deduplicate: Compare resolved URLs or bookmarks?
            // Bookmarks can vary even for same file. Best to resolve existing ones to check path equality,
            // OR checks if we can resolve the new bookmark to the same path.
            // Simplified approach: Remove by path if possible, but safer to rely on internal logic.
            // Let's filter based on resolving existing bookmarks quickly.
            recentFiles.removeAll { file in
                if let resolved = try? bookmarking.resolveBookmarkData(file.bookmark, options: .withoutUI, relativeTo: nil).url {
                    return resolved.path == url.path
                }
                return false
            }
            
            let newFile = RecentFile(
                bookmark: data,
                displayName: url.lastPathComponent,
                date: Date(),
                pageCount: pageCount
            )
            
            recentFiles.insert(newFile, at: 0)
            
            // Trim
            if recentFiles.count > maxRecentFiles {
                recentFiles = Array(recentFiles.prefix(maxRecentFiles))
            }
            
            save()
        } catch {
            print("Failed to create bookmark for \(url): \(error)")
        }
    }
    
    /// Finds an existing recent file entry matching the given URL.
    func find(url: URL) -> RecentFile? {
        return recentFiles.first { file in
            if let resolved = try? bookmarking.resolveBookmarkData(file.bookmark, options: .withoutUI, relativeTo: nil).url {
                return resolved.path == url.path
            }
            return false
        }
    }
    
    /// Removes a specific recent file entry.
    func remove(_ file: RecentFile) {
        recentFiles.removeAll { $0.id == file.id }
        save()
    }
    
    /// Resolves a RecentFile to a usable URL and access token.
    /// - Returns: Tuple of (URL, AccessToken). Calling code must keep AccessToken alive while using the file.
    func resolveForOpen(_ file: RecentFile) throws -> (url: URL, access: SecurityScopedAccess) {
        // Resolve with security scope
        let result = try bookmarking.resolveBookmarkData(file.bookmark, options: .withSecurityScope, relativeTo: nil)
        
        // If stale, we should ideally update the bookmark, but that requires write access or a new pick.
        // We can at least update the in-memory list if the URL changed but is valid.
        if result.isStale {
            // Re-bookmark the new URL if valid
            if let newData = try? bookmarking.bookmarkData(for: result.url, includingResourceValuesForKeys: nil, relativeTo: nil) {
                if let index = recentFiles.firstIndex(where: { $0.id == file.id }) {
                    var updated = recentFiles[index]
                    updated = RecentFile(id: updated.id, bookmark: newData, displayName: result.url.lastPathComponent, date: Date(), pageCount: updated.pageCount)
                    recentFiles[index] = updated
                    save()
                }
            }
        }
        
        let access = SecurityScopedAccess(url: result.url)
        return (result.url, access)
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(recentFiles) {
            defaults.set(data, forKey: storageKey)
        }
    }
    
    private func load() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) {
            recentFiles = decoded
        }
    }
}
