import SwiftUI

struct AIActivityView: View {
    @EnvironmentObject private var aiInteractions: AIInteractionStore
    @State private var selection: AIInteractionEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppTheme.Colors.cardBorder.opacity(0.6))
            HSplitView {
                activityList
                detailView
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .background(AppTheme.Colors.background)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("AI evidence log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.support)
                Text("Review local prompts, responses, and model routing")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.primaryText)
                Text("Inspect how OCR, summary, extraction, and translation tasks were handled before trusting the output.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }

            Spacer()

            Button("Clear Log") {
                aiInteractions.clear()
                selection = nil
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(aiInteractions.entries.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(AppTheme.Colors.sidebarBackground)
    }

    private var activityList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader("Runs", detail: aiInteractions.entries.isEmpty ? "No local AI interactions captured yet." : "\(aiInteractions.entries.count) captured interactions.")

                if aiInteractions.entries.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No AI runs recorded yet")
                            .appFont(.headline)
                            .foregroundStyle(AppTheme.Colors.primaryText)
                        Text("Run a local summarize, translate, extract, or OCR task from QuickFix to build an inspectable history here.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    }
                    .cardStyle()
                } else {
                    ForEach(aiInteractions.entries) { entry in
                        Button {
                            selection = entry.id
                        } label: {
                            activityRow(for: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 290)
        .background(AppTheme.Colors.sidebarBackground)
    }

    private func activityRow(for entry: AIInteractionEntry) -> some View {
        let isSelected = selection == entry.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Label(entry.task.displayName, systemImage: entry.task.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.primaryText)
                Spacer()
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }

            Text(entry.model)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.support)

            if let source = entry.sourceName {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if entry.inputWasTrimmed {
                Text("Prompt trimmed to fit local context window.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                .fill(isSelected ? AppTheme.Colors.accentSoft : AppTheme.Colors.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                .stroke(isSelected ? AppTheme.Colors.accent.opacity(0.55) : AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }

    private var detailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let entry = aiInteractions.entries.first(where: { $0.id == selection }) {
                    sectionHeader("Inspection", detail: "Prompt, response, and source details for the selected run.")

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(entry.task.displayName, systemImage: entry.task.systemImage)
                                .font(.headline)
                                .foregroundStyle(AppTheme.Colors.primaryText)
                            Spacer()
                            Text(entry.timestamp, style: .date)
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                        }

                        keyValueRow("Model", value: entry.model)
                        if let source = entry.sourceName {
                            keyValueRow("Source", value: source)
                        }
                        if entry.inputWasTrimmed {
                            keyValueRow("Input", value: "Trimmed from \(entry.inputCharacterCount) characters")
                        }
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Prompt")
                            .appFont(.headline)
                            .foregroundStyle(AppTheme.Colors.paperText)
                        Text(entry.prompt)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.Colors.paperText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .paperPanelStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Response")
                            .appFont(.headline)
                            .foregroundStyle(AppTheme.Colors.paperText)
                        Text(entry.response)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.Colors.paperText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .paperPanelStyle()
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Select a run to inspect")
                            .appFont(.headline)
                            .foregroundStyle(AppTheme.Colors.primaryText)
                        Text("Use the left column to review the prompt, response, and model details for a local AI task.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    }
                    .cardStyle()
                }
            }
            .padding(20)
        }
        .background(AppTheme.Colors.background)
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
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.secondaryText)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}
