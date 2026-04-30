import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var aiSettings: LocalAISettings
    @EnvironmentObject private var aiInteractions: AIInteractionStore
    @State private var outputBookmarkCount: Int = OutputDirectoryAccessStore.shared.count
    @State private var outputBookmarkStatus: String?

    private let autoTag = "__default__"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                localAISection
                defaultModelSection
                taskOverridesSection
                outputSection
            }
            .padding(20)
        }
        .frame(width: 520)
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .task {
            await aiSettings.refreshModelsIfNeeded()
        }
        .onAppear {
            aiInteractions.setPersistence(enabled: aiSettings.persistAIInteractions)
            outputBookmarkCount = OutputDirectoryAccessStore.shared.count
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local AI control room")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.support)
            Text("Configure private OCR and model behavior")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.primaryText)
            Text("Keep model routing, persistence, and output access aligned with the cleanup workflow on this Mac.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.Colors.secondaryText)
        }
    }

    private var localAISection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Local AI", detail: "Connection, persistence, and model refresh.")

            keyValueRow("Ollama host", value: "127.0.0.1:11434")

            Toggle("Persist AI interactions between launches", isOn: $aiSettings.persistAIInteractions)
                .toggleStyle(.switch)
                .onChange(of: aiSettings.persistAIInteractions) { enabled in
                    aiInteractions.setPersistence(enabled: enabled)
                }

            Stepper(
                value: $aiSettings.requestTimeoutSeconds,
                in: LocalAISettings.minRequestTimeoutSeconds ... LocalAISettings.maxRequestTimeoutSeconds,
                step: 10
            ) {
                Text("AI request timeout: \(aiSettings.requestTimeoutSeconds)s")
                    .foregroundStyle(AppTheme.Colors.primaryText)
            }

            HStack(spacing: 12) {
                Button(aiSettings.isRefreshing ? "Refreshing…" : "Refresh Models") {
                    Task { await aiSettings.refreshModels() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(aiSettings.isRefreshing)

                if let error = aiSettings.lastRefreshError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.warning)
                }
            }
        }
        .cardStyle()
    }

    private var defaultModelSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Default Model", detail: "Primary local model used when a task has no override.")

            if aiSettings.availableModels.isEmpty {
                Text("No local Ollama models detected. Install models with ollama and refresh.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            } else {
                Picker("Default model", selection: $aiSettings.defaultModel) {
                    ForEach(aiSettings.availableModels) { model in
                        Text(aiSettings.displayName(for: model.name)).tag(model.name)
                    }
                }

                if let recommended = aiSettings.recommendedModelName {
                    Text("Recommended: \(aiSettings.displayName(for: recommended))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.support)
                }
            }
        }
        .cardStyle()
    }

    private var taskOverridesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Task Overrides", detail: "Assign specific local models to cleanup tasks where needed.")

            if aiSettings.availableModels.isEmpty {
                Text("Load models to configure per-task overrides.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            } else {
                ForEach(LocalAITask.allCases) { task in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                        Picker(task.displayName, selection: overrideBinding(for: task)) {
                            Text("Use Default (\(aiSettings.displayName(for: aiSettings.defaultModel)))")
                                .tag(autoTag)
                            ForEach(aiSettings.availableModels) { model in
                                Text(aiSettings.displayName(for: model.name)).tag(model.name)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
        }
        .cardStyle()
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("QuickFix Output", detail: "Manage saved export destinations used by cleanup flows.")

            keyValueRow("Saved output folders", value: "\(outputBookmarkCount)")

            HStack(spacing: 12) {
                Button("Clear Saved Output Folders") {
                    OutputDirectoryAccessStore.shared.clear()
                    outputBookmarkCount = OutputDirectoryAccessStore.shared.count
                    outputBookmarkStatus = "Cleared."
                }
                .buttonStyle(SecondaryButtonStyle())

                if let outputBookmarkStatus {
                    Text(outputBookmarkStatus)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.support)
                }
            }
        }
        .cardStyle()
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(.headline)
                .foregroundStyle(AppTheme.Colors.primaryText)
            Text(detail)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText)
        }
    }

    private func keyValueRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(AppTheme.Colors.secondaryText)
            Spacer()
            Text(value)
                .foregroundStyle(AppTheme.Colors.primaryText)
        }
        .font(.caption)
    }

    private func overrideBinding(for task: LocalAITask) -> Binding<String> {
        Binding<String>(
            get: {
                aiSettings.override(for: task) ?? autoTag
            },
            set: { newValue in
                let value = newValue == autoTag ? nil : newValue
                aiSettings.setOverride(task: task, model: value)
            }
        )
    }
}
