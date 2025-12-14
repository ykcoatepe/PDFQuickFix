import Foundation

/// Protocol for bookmarking operations to allow dependency injection and testing.
protocol Bookmarking {
    /// Creates bookmark data for the given URL.
    /// - Parameters:
    ///   - url: The file URL to bookmark.
    ///   - includingResourceValuesForKeys: Resource keys to include (optional).
    ///   - relativeTo: The URL relative to which the bookmark is made (optional).
    /// - Returns: The bookmark data.
    func bookmarkData(for url: URL, includingResourceValuesForKeys keys: Set<URLResourceKey>?, relativeTo relativeURL: URL?) throws -> Data
    
    /// Resolves bookmark data into a URL.
    /// - Parameters:
    ///   - data: The bookmark data.
    ///   - options: Resolution options (e.g., withSecurityScope).
    ///   - relativeTo: The URL relative to which the bookmark was made (optional).
    /// - Returns: A tuple containing the resolved URL and a boolean indicating if the data is stale.
    func resolveBookmarkData(_ data: Data, options: URL.BookmarkResolutionOptions, relativeTo relativeURL: URL?) throws -> (url: URL, isStale: Bool)
}

/// Default system implementation of Bookmarking using URL APIs.
struct SystemBookmarking: Bookmarking {
    func bookmarkData(for url: URL, includingResourceValuesForKeys keys: Set<URLResourceKey>?, relativeTo relativeURL: URL?) throws -> Data {
        // Essential security options: securityScopeAllowOnlyReadAccess by default?
        // Actually, we usually want read/write if the user gave us that (standard open panel).
        // Creation of bookmark with security scope is implicit if the URL has one.
        // We ensure we ask for securityScope in the options if we are capable.
        // The standard API call usually handles this if the file is security scoped.
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: keys, relativeTo: relativeURL)
    }
    
    func resolveBookmarkData(_ data: Data, options: URL.BookmarkResolutionOptions, relativeTo relativeURL: URL?) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: relativeURL, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }
}

/// A wrapper class that manages the lifecycle of a security-scoped resource.
/// Calls `startAccessingSecurityScopedResource()` on init and `stopAccessingSecurityScopedResource()` on deinit.
final class SecurityScopedAccess {
    let url: URL
    private var isAccessing: Bool = false
    
    init(url: URL) {
        self.url = url
        self.isAccessing = url.startAccessingSecurityScopedResource()
    }
    
    deinit {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
    
    /// Explicitly stops accessing if needed before deinit.
    func stopAccess() {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
            isAccessing = false
        }
    }
}
