import SwiftUI

/// Centralized palette and layout metrics shared across PDFQuickFix surfaces.
/// Values are aligned with the current Reader facelift so other modules can
/// reuse the same look without duplicating constants.
enum AppTheme {

    enum Colors {
        // Core surfaces
        static let background = Color(red: 0.09, green: 0.09, blue: 0.11)      // ~#18181B
        static let sidebarBackground = Color(red: 0.10, green: 0.10, blue: 0.12)
        static let cardBackground = Color(red: 0.15, green: 0.15, blue: 0.17)   // ~#27272A
        static let cardBorder = Color.white.opacity(0.08)

        // Drop zone
        static let dropZoneStroke = Color.white.opacity(0.28)
        static let dropZoneFill = Color.white.opacity(0.08)
        static let dropZoneFillHighlighted = Color.white.opacity(0.16)

        // Thumbnails / document icon
        static let thumbnailBackground = Color.white.opacity(0.95)
        static let thumbnailBorder = Color.black.opacity(0.06)

        // Text
        static let primaryText = Color.white
        static let secondaryText = Color.white.opacity(0.68)
    }

    enum Metrics {
        static let cardCornerRadius: CGFloat = 12
        static let dropZoneCornerRadius: CGFloat = 16
        static let thumbnailCornerRadius: CGFloat = 6
        static let cardBorderWidth: CGFloat = 1
        static let dropZoneBorderWidth: CGFloat = 1.5
        static let homePanelCornerRadius: CGFloat = 22
        static let homePanelHorizontalPadding: CGFloat = 40
    }

    enum Shadows {
        static let card = Color.black.opacity(0.35)
    }
}
