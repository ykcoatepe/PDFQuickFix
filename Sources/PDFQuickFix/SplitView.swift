import SwiftUI
import AppKit

struct SplitView: View {
    @Binding var selectedTab: AppMode
    @StateObject private var controller = SplitController()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar handled by UnifiedToolbar in ContentView

            VStack(spacing: 16) {
                header
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 24)

                mainPanel
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 24)

                footer
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 24)
            }
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(AppTheme.Colors.background)
        }
        .background(AppTheme.Colors.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Split PDF")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(AppTheme.Colors.primaryText)
                Text("Split large PDFs into smaller parts, chapters, or batches.")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var mainPanel: some View {
        RoundedRectangle(cornerRadius: AppTheme.Metrics.homePanelCornerRadius, style: .continuous)
            .fill(AppTheme.Colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Metrics.homePanelCornerRadius, style: .continuous)
                    .stroke(AppTheme.Colors.cardBorder, lineWidth: AppTheme.Metrics.cardBorderWidth)
            )
            .overlay(
                VStack(alignment: .leading, spacing: 16) {
                    SplitSourceCard(
                        sourceURL: controller.sourceURL,
                        onChooseSource: chooseSource,
                        onDropURL: { url in controller.setSource(url: url) }
                    )
                    .frame(minHeight: 170)

                    SplitModeCard(
                        mode: $controller.mode,
                        maxPagesPerFile: $controller.maxPagesPerFile,
                        numberOfParts: $controller.numberOfParts,
                        approxSizeMB: $controller.approxSizeMB,
                        explicitBreaksText: $controller.explicitBreaksText
                    )

                    SplitDestinationCard(
                        destinationURL: controller.destinationURL,
                        applyToAllPDFsInFolder: $controller.applyToAllPDFsInFolder,
                        onChooseDestination: chooseDestination
                    )

                    SplitHistoryCard(history: Array(controller.history.suffix(6)))
                }
                .padding(16)
            )
    }

    private var footer: some View {
        footerContent
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                    .fill(AppTheme.Colors.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                            .stroke(AppTheme.Colors.cardBorder, lineWidth: AppTheme.Metrics.cardBorderWidth)
                    )
            )
    }

    private var footerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.status)
                    .font(.footnote)
                    .foregroundColor(AppTheme.Colors.primaryText)

                if let progress = controller.progressText {
                    Text(progress)
                        .font(.caption)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                }

                if controller.isWorking {
                    if let value = controller.progressValue {
                        ProgressView(value: value)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                    }
                }
            }

            HStack(spacing: 12) {
                if !controller.lastOutputFiles.isEmpty {
                    Button {
                        revealInFinder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(action: controller.split) {
                    if controller.isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Splitting…")
                        }
                    } else {
                        Label("Split", systemImage: "scissors")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(!controller.canSplit || controller.isWorking)
            }
        }
        .foregroundColor(AppTheme.Colors.primaryText)
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.setSource(url: url)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            controller.setDestination(url: url)
        }
    }

    private func revealInFinder() {
        guard !controller.lastOutputFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(controller.lastOutputFiles)
    }
}
