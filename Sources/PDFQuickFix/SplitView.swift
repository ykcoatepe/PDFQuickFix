import SwiftUI
import AppKit

enum SplitWorkspaceMode: String, CaseIterable, Identifiable {
    case split = "Split"
    case merge = "Merge"

    var id: String { rawValue }
}

struct SplitView: View {
    @Binding var selectedTab: AppMode
    @StateObject private var splitController = SplitController()
    @StateObject private var mergeController = MergeController()
    @State private var workspaceMode: SplitWorkspaceMode = .split

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                header
                    .frame(maxWidth: 900)
                    .padding(.horizontal, 24)

                modeSelector
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
        .onChange(of: selectedTab) { _ in
            // Keep local segmented mode within Split workspace only.
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Output workbench")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.Colors.support)
                Text(workspaceMode == .split ? "Split outbound copies" : "Assemble outbound packet")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(AppTheme.Colors.primaryText)
                Text(workspaceMode == .split
                     ? "Break a PDF into smaller, reviewable outputs for safer sharing."
                     : "Merge multiple PDFs into one reviewable document with controlled ordering and fallback rules.")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeSelector: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(SplitWorkspaceMode.allCases) { mode in
                    Button {
                        workspaceMode = mode
                    } label: {
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(workspaceMode == mode ? AppTheme.Colors.primaryText : AppTheme.Colors.secondaryText)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minWidth: 88)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(workspaceMode == mode ? AppTheme.Colors.accentSoft : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(workspaceMode == mode ? AppTheme.Colors.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppTheme.Colors.elevatedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
            )
            Spacer()
        }
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
                    if workspaceMode == .split {
                        splitPanel
                    } else {
                        mergePanel
                    }
                }
                .padding(16)
            )
    }

    private var splitPanel: some View {
        Group {
            SplitSourceCard(
                sourceURL: splitController.sourceURL,
                onChooseSource: chooseSplitSource,
                onDropURL: { url in splitController.setSource(url: url) }
            )
            .frame(minHeight: 170)

            SplitModeCard(
                mode: $splitController.mode,
                maxPagesPerFile: $splitController.maxPagesPerFile,
                numberOfParts: $splitController.numberOfParts,
                approxSizeMB: $splitController.approxSizeMB,
                explicitBreaksText: $splitController.explicitBreaksText
            )

            SplitDestinationCard(
                destinationURL: splitController.destinationURL,
                applyToAllPDFsInFolder: $splitController.applyToAllPDFsInFolder,
                onChooseDestination: chooseSplitDestination
            )

            SplitHistoryCard(history: Array(splitController.history.suffix(6)))
        }
    }

    private var mergePanel: some View {
        Group {
            MergeSourceListCard(
                sourceURLs: mergeController.sourceURLs,
                deduplicateSources: mergeController.deduplicateSources,
                onChooseSources: mergeController.chooseSources,
                onDropURL: { url in mergeController.addSourceURLs([url]) },
                onRemoveOffsets: mergeController.removeSource,
                onMove: mergeController.moveSource,
                onClear: mergeController.clearSources
            )

            MergeOptionsCard(
                insertBlankPageBetweenDocuments: $mergeController.insertBlankPageBetweenDocuments,
                skipUnreadableSources: $mergeController.skipUnreadableSources,
                deduplicateSources: $mergeController.deduplicateSources,
                outlinePolicy: $mergeController.outlinePolicy,
                metadataPolicy: $mergeController.metadataPolicy
            )

            MergeDestinationCard(
                destinationFolderURL: mergeController.destinationFolderURL,
                outputFileName: $mergeController.outputFileName,
                onChooseDestination: mergeController.chooseDestination
            )

            MergeHistoryCard(history: Array(mergeController.history.suffix(6)))
        }
    }

    private var footer: some View {
        Group {
            if workspaceMode == .split {
                splitFooter
            } else {
                mergeFooter
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                .fill(AppTheme.Colors.elevatedBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                        .stroke(AppTheme.Colors.cardBorder, lineWidth: AppTheme.Metrics.cardBorderWidth)
                )
        )
    }

    private var splitFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(splitController.status)
                    .font(.footnote)
                    .foregroundColor(AppTheme.Colors.primaryText)

                if let progress = splitController.progressText {
                    Text(progress)
                        .font(.caption)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                }

                if splitController.isWorking {
                    if let value = splitController.progressValue {
                        ProgressView(value: value)
                            .progressViewStyle(.linear)
                            .tint(AppTheme.Colors.accent)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(AppTheme.Colors.accent)
                    }
                }
            }

            HStack(spacing: 12) {
                if !splitController.lastOutputFiles.isEmpty {
                    Button {
                        revealSplitOutputInFinder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(action: splitController.split) {
                    if splitController.isWorking {
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
                .tint(AppTheme.Colors.accent)
                .disabled(!splitController.canSplit || splitController.isWorking)
            }
        }
        .foregroundColor(AppTheme.Colors.primaryText)
    }

    private var mergeFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(mergeController.status)
                    .font(.footnote)
                    .foregroundColor(AppTheme.Colors.primaryText)

                if !mergeController.warnings.isEmpty {
                    ForEach(Array(mergeController.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(.caption)
                            .foregroundColor(AppTheme.Colors.warning)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            HStack(spacing: 12) {
                if mergeController.lastOutputURL != nil {
                    Button {
                        mergeController.revealOutputInFinder()
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(action: mergeController.merge) {
                    if mergeController.isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Merging…")
                        }
                    } else {
                        Label("Merge", systemImage: "link")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.Colors.accent)
                .disabled(!mergeController.canMerge || mergeController.isWorking)
            }
        }
        .foregroundColor(AppTheme.Colors.primaryText)
    }

    private func chooseSplitSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            splitController.setSource(url: url)
        }
    }

    private func chooseSplitDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            splitController.setDestination(url: url)
        }
    }

    private func revealSplitOutputInFinder() {
        guard !splitController.lastOutputFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(splitController.lastOutputFiles)
    }

}
