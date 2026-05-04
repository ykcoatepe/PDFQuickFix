import Foundation

@MainActor
final class LocalAISettings: ObservableObject {
    static let defaultModelKey = "LocalAI.defaultModel"
    static let selectedProviderKey = "LocalAI.selectedProvider"
    static let persistLogsKey = "LocalAI.persistLogs"
    static let overridePrefix = "LocalAI.override."
    static let requestTimeoutKey = "LocalAI.requestTimeoutSeconds"
    static let minRequestTimeoutSeconds = 20
    static let maxRequestTimeoutSeconds = 300
    static let defaultRequestTimeoutSeconds = 120

    @Published private(set) var availableModels: [OllamaModelInfo] = []
    @Published private(set) var lastRefreshError: String?
    @Published private(set) var isRefreshing: Bool = false
    @Published var selectedProvider: LocalAIProvider {
        didSet {
            defaults.set(selectedProvider.rawValue, forKey: Self.selectedProviderKey)
            defaultModel = defaults.string(forKey: Self.defaultModelKey(for: selectedProvider)) ?? ""
            taskOverrides = Self.loadOverrides(for: selectedProvider, defaults: defaults)
            availableModels = []
            lastRefreshError = nil
            hasLoadedModels = false
        }
    }

    @Published var defaultModel: String {
        didSet {
            defaults.set(defaultModel, forKey: Self.defaultModelKey(for: selectedProvider))
        }
    }

    @Published var persistAIInteractions: Bool {
        didSet {
            defaults.set(persistAIInteractions, forKey: Self.persistLogsKey)
        }
    }

    @Published var requestTimeoutSeconds: Int {
        didSet {
            let clamped = Self.clampTimeout(requestTimeoutSeconds)
            if clamped != requestTimeoutSeconds {
                requestTimeoutSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Self.requestTimeoutKey)
        }
    }

    @Published private(set) var taskOverrides: [LocalAITask: String] = [:]

    private let ollamaClient: OllamaClient
    private let lmStudioClient: LMStudioClient
    private let defaults: UserDefaults
    private var hasLoadedModels = false

    init(client: OllamaClient = OllamaClient(),
         lmStudioClient: LMStudioClient = LMStudioClient(),
         defaults: UserDefaults = .standard)
    {
        ollamaClient = client
        self.lmStudioClient = lmStudioClient
        self.defaults = defaults
        let savedProvider = defaults.string(forKey: Self.selectedProviderKey)
            .flatMap(LocalAIProvider.init(rawValue:)) ?? .ollama
        selectedProvider = savedProvider
        defaultModel = defaults.string(forKey: Self.defaultModelKey(for: savedProvider))
            ?? defaults.string(forKey: Self.defaultModelKey)
            ?? ""
        persistAIInteractions = defaults.bool(forKey: Self.persistLogsKey)
        if defaults.object(forKey: Self.requestTimeoutKey) != nil {
            requestTimeoutSeconds = defaults.integer(forKey: Self.requestTimeoutKey)
        } else {
            requestTimeoutSeconds = Self.defaultRequestTimeoutSeconds
        }
        requestTimeoutSeconds = Self.clampTimeout(requestTimeoutSeconds)
        taskOverrides = Self.loadOverrides(for: savedProvider, defaults: defaults)
    }

    func refreshModelsIfNeeded() async {
        if !hasLoadedModels {
            await refreshModels()
        }
    }

    func refreshModels() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshError = nil
        defer {
            isRefreshing = false
            hasLoadedModels = true
        }

        do {
            var models = try await modelListingClient().listModels()
            models = models.filter { !Self.isCloudModel($0.name) }
            models.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            availableModels = models
            normalizeModels()
        } catch {
            lastRefreshError = "\(selectedProvider.displayName) not reachable on \(selectedProvider.hostLabel)."
        }
    }

    func modelFor(task: LocalAITask) -> String? {
        let names = availableModelNamesLowercased()
        if let override = taskOverrides[task], names.contains(override.lowercased()) {
            return override
        }
        if names.contains(defaultModel.lowercased()) {
            return defaultModel
        }
        return nil
    }

    func setOverride(task: LocalAITask, model: String?) {
        if let model {
            taskOverrides[task] = model
            defaults.set(model, forKey: Self.overrideKey(for: task, provider: selectedProvider))
        } else {
            taskOverrides.removeValue(forKey: task)
            defaults.removeObject(forKey: Self.overrideKey(for: task, provider: selectedProvider))
        }
    }

    func override(for task: LocalAITask) -> String? {
        taskOverrides[task]
    }

    func displayName(for model: String) -> String {
        if Self.isOCRModel(model) {
            return "\(model) (OCR-only)"
        }
        return model
    }

    var recommendedModelName: String? {
        Self.recommendedModelName(models: availableModels)
    }

    func makeTextClient() -> LocalAITextGenerating {
        switch selectedProvider {
        case .ollama:
            OllamaClient(requestTimeout: TimeInterval(requestTimeoutSeconds))
        case .lmStudio:
            LMStudioClient(requestTimeout: TimeInterval(requestTimeoutSeconds))
        }
    }

    private func normalizeModels() {
        let availableNames = availableModelNamesLowercased()
        if !defaultModel.isEmpty, !availableNames.contains(defaultModel.lowercased()) {
            defaultModel = ""
        }
        let invalidTasks = taskOverrides.filter { !availableNames.contains($0.value.lowercased()) }.map(\.key)
        for task in invalidTasks {
            taskOverrides.removeValue(forKey: task)
            defaults.removeObject(forKey: Self.overrideKey(for: task, provider: selectedProvider))
        }
        if defaultModel.isEmpty, let recommended = recommendedModelName {
            defaultModel = recommended
        }
    }

    private func availableModelNamesLowercased() -> Set<String> {
        Set(availableModels.map { $0.name.lowercased() })
    }

    private func modelListingClient() -> any LocalAIModelListing {
        switch selectedProvider {
        case .ollama: ollamaClient
        case .lmStudio: lmStudioClient
        }
    }

    private static func defaultModelKey(for provider: LocalAIProvider) -> String {
        "\(defaultModelKey).\(provider.rawValue)"
    }

    private static func overrideKey(for task: LocalAITask, provider: LocalAIProvider) -> String {
        "\(overridePrefix)\(provider.rawValue).\(task.rawValue)"
    }

    private static func loadOverrides(for provider: LocalAIProvider, defaults: UserDefaults) -> [LocalAITask: String] {
        var overrides: [LocalAITask: String] = [:]
        for task in LocalAITask.allCases {
            let providerKey = overrideKey(for: task, provider: provider)
            let legacyKey = overridePrefix + task.rawValue
            if let value = defaults.string(forKey: providerKey) ?? defaults.string(forKey: legacyKey) {
                overrides[task] = value
            }
        }
        return overrides
    }

    private static func isCloudModel(_ name: String) -> Bool {
        name.lowercased().contains(":cloud")
    }

    private static func isOCRModel(_ name: String) -> Bool {
        name.lowercased().contains("ocr")
    }

    private static func recommendedModelName(models: [OllamaModelInfo]) -> String? {
        guard !models.isEmpty else { return nil }
        if let deepseek = matchModelName("deepseek-r1:8b", in: models) {
            return deepseek
        }
        let nonOCR = models.filter { !isOCRModel($0.name) }
        let candidates = nonOCR.isEmpty ? models : nonOCR
        let sorted = candidates.sorted { lhs, rhs in
            modelRank(lhs.name) < modelRank(rhs.name)
        }
        return sorted.first?.name
    }

    private static func modelRank(_ name: String) -> (Int, Int, Int, String) {
        let lower = name.lowercased()
        let size = modelSizeHint(lower)
        let instructPenalty = lower.contains("instruct") || lower.contains("chat") ? 0 : 1
        let visionPenalty = lower.contains("vl") ? 1 : 0
        return (instructPenalty, size, visionPenalty, lower)
    }

    private static func modelSizeHint(_ name: String) -> Int {
        let pattern = #"(\d+)\s*b"#
        if let range = name.range(of: pattern, options: .regularExpression) {
            let digits = name[range].filter(\.isNumber)
            return Int(digits) ?? 999
        }
        return 999
    }

    private static func matchModelName(_ target: String, in models: [OllamaModelInfo]) -> String? {
        models.first { $0.name.lowercased() == target.lowercased() }?.name
    }

    private static func clampTimeout(_ value: Int) -> Int {
        min(max(value, minRequestTimeoutSeconds), maxRequestTimeoutSeconds)
    }
}
