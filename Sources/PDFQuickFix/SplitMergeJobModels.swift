import AppKit
import Foundation

struct SplitJobSettings: Codable, Hashable {
    var sourceURLString: String?
    var sourceBookmarkData: Data? = nil
    var destinationURLString: String?
    var destinationBookmarkData: Data? = nil
    var applyToAllPDFsInFolder: Bool
    var mode: SplitUIMode
    var maxPagesPerFile: Int
    var numberOfParts: Int
    var approxSizeMB: Double
    var explicitBreaksText: String
}

struct SplitJobPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var settings: SplitJobSettings
}

struct SplitJobRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let settings: SplitJobSettings
    let sourceDescription: String
    let modeDescription: String
    let fileCount: Int
    let outputCount: Int
    let destinationFolder: String
    let errorSummary: String?
}

struct MergeJobSettings: Codable, Hashable {
    var sourceURLStrings: [String]
    var destinationFolderURLString: String?
    var outputFileName: String
    var insertBlankPageBetweenDocuments: Bool
    var skipUnreadableSources: Bool
    var deduplicateSources: Bool
    var outlinePolicy: MergeOutlinePolicy
    var metadataPolicy: MergeMetadataPolicy
}

struct MergeJobPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date
    var settings: MergeJobSettings
}

struct MergeJobRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let settings: MergeJobSettings
    let sourceCount: Int
    let mergedDocumentCount: Int
    let mergedPageCount: Int
    let destinationFolder: String
    let outputFileName: String
    let skippedCount: Int
    let warningsSummary: String?
}

enum CodableUserDefaultsStore {
    static func loadArray<T: Codable>(_ type: [T].Type, key: String, defaults: UserDefaults) -> [T] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([T].self, from: data) else {
            return []
        }
        return decoded
    }

    static func saveArray<T: Codable>(_ values: [T], key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
func promptForText(title: String, message: String, defaultValue: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .informational

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = defaultValue
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return nil }
    let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
