import Foundation

struct RecentFile: Identifiable, Codable {
    var id: UUID = UUID()
    let url: URL
    let date: Date
    let pageCount: Int
    
    var name: String {
        url.lastPathComponent
    }
}

class RecentFilesManager: ObservableObject {
    static let shared = RecentFilesManager()
    
    @Published var recentFiles: [RecentFile] = []
    
    private let maxRecentFiles = 10
    private let storageKey = "PDFQuickFix_RecentFiles"
    
    private init() {
        load()
    }
    
    func add(url: URL, pageCount: Int) {
        // Remove existing entry if present
        recentFiles.removeAll { $0.url == url }
        
        // Add new entry to top
        let newFile = RecentFile(url: url, date: Date(), pageCount: pageCount)
        recentFiles.insert(newFile, at: 0)
        
        // Trim
        if recentFiles.count > maxRecentFiles {
            recentFiles = Array(recentFiles.prefix(maxRecentFiles))
        }
        
        save()
    }
    
    private func save() {
        if let data = try? JSONEncoder().encode(recentFiles) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
    
    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RecentFile].self, from: data) {
            recentFiles = decoded
        }
    }
}
