import SwiftUI

enum BatchSanitizeButtonTone {
    case primary
    case secondary
    case ghost
}

struct BatchSanitizeLaunchButton: View {
    var title: String = "Sanitize Folder…"
    var tone: BatchSanitizeButtonTone = .secondary

    @ViewBuilder
    var body: some View {
        switch tone {
        case .primary:
            button.buttonStyle(PrimaryButtonStyle())
        case .secondary:
            button.buttonStyle(SecondaryButtonStyle())
        case .ghost:
            button.buttonStyle(GhostButtonStyle())
        }
    }

    private var button: some View {
        Button {
            BatchSanitizeCoordinator.shared.showBatchSanitizePanel()
        } label: {
            Label(title, systemImage: "folder")
        }
    }
}

struct BatchSanitizeWorkbenchCallout: View {
    var eyebrow: String = "Batch outbound copies"
    var title: String = "Sanitize a folder into reviewed outbound copies"
    var detail: String = "Choose a source folder, write sanitized copies to a separate destination, and review the receipt before handoff."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(eyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.support)
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.primaryText)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    cuePill("Separate output folder")
                    cuePill("Run receipt")
                    cuePill("Originals untouched")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        cuePill("Separate output folder")
                        cuePill("Run receipt")
                    }
                    cuePill("Originals untouched")
                }
            }

            HStack(spacing: 10) {
                BatchSanitizeLaunchButton()
                Spacer(minLength: 0)
                Text("Folder-wide lane")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.support)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                .fill(AppTheme.Colors.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                .stroke(AppTheme.Colors.cardBorder, lineWidth: AppTheme.Metrics.cardBorderWidth)
        )
    }

    private func cuePill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AppTheme.Colors.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.Colors.accentSoft)
            )
    }
}
