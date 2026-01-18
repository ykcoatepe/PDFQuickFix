import Foundation

struct AIInteractionEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let task: LocalAITask
    let model: String
    let prompt: String
    let response: String
    let sourceName: String?
    let inputCharacterCount: Int
    let inputWasTrimmed: Bool
}

@MainActor
final class AIInteractionStore: ObservableObject {
    @Published private(set) var entries: [AIInteractionEntry] = []

    private let maxEntries = 200
    private let maxPromptCharacters = 4000
    private let maxResponseCharacters = 8000
    private var persistToDisk: Bool
    private let fileURL: URL

    init(persistToDisk: Bool = UserDefaults.standard.bool(forKey: "LocalAI.persistLogs")) {
        self.persistToDisk = persistToDisk
        self.fileURL = AIInteractionStore.makeFileURL()
        if persistToDisk {
            load()
        }
    }

    func setPersistence(enabled: Bool) {
        guard enabled != persistToDisk else { return }
        persistToDisk = enabled
        if enabled {
            load()
        } else {
            deletePersisted()
        }
    }

    func record(_ entry: AIInteractionEntry) {
        let sanitized = sanitize(entry)
        entries.insert(sanitized, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        if persistToDisk {
            save()
        }
    }

    func clear() {
        entries = []
        if persistToDisk {
            save()
        } else {
            deletePersisted()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Best-effort persistence; ignore failures in UI flow.
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AIInteractionEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func deletePersisted() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func sanitize(_ entry: AIInteractionEntry) -> AIInteractionEntry {
        let prompt = truncate(entry.prompt, limit: maxPromptCharacters)
        let response = truncate(entry.response, limit: maxResponseCharacters)
        guard prompt != entry.prompt || response != entry.response else { return entry }
        return AIInteractionEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            task: entry.task,
            model: entry.model,
            prompt: prompt,
            response: response,
            sourceName: entry.sourceName,
            inputCharacterCount: entry.inputCharacterCount,
            inputWasTrimmed: entry.inputWasTrimmed
        )
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "... (truncated)"
    }

    private static func makeFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("PDFQuickFix", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("ai-interactions.json")
    }
}
