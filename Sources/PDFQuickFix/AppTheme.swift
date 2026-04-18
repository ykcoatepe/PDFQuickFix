import SwiftUI

/// Centralized palette and layout metrics shared across PDFQuickFix surfaces.
/// Values are aligned with the current Reader facelift so other modules can
/// reuse the same look without duplicating constants.
enum AppTheme {

    enum Colors {
        // Core surfaces
        static let background = Color(red: 0.06, green: 0.07, blue: 0.07)       // ~#0F1113
        static let sidebarBackground = Color(red: 0.09, green: 0.10, blue: 0.12)
        static let cardBackground = Color(red: 0.13, green: 0.15, blue: 0.17)   // ~#22262B
        static let elevatedBackground = Color(red: 0.17, green: 0.19, blue: 0.22)
        static let cardBorder = Color(red: 0.85, green: 0.82, blue: 0.76).opacity(0.12)

        // Drop zone
        static let dropZoneStroke = Color(red: 0.73, green: 0.69, blue: 0.62).opacity(0.35)
        static let dropZoneFill = Color(red: 0.91, green: 0.89, blue: 0.85).opacity(0.06)
        static let dropZoneFillHighlighted = accent.opacity(0.12)

        // Thumbnails / document icon
        static let thumbnailBackground = Color(red: 0.96, green: 0.94, blue: 0.91)
        static let thumbnailBorder = Color.black.opacity(0.08)

        // Paper surfaces
        static let paperBackground = Color(red: 0.96, green: 0.94, blue: 0.91)
        static let paperBorder = Color(red: 0.85, green: 0.82, blue: 0.76)
        static let paperText = Color(red: 0.16, green: 0.15, blue: 0.13)

        // Text
        static let primaryText = Color(red: 0.91, green: 0.89, blue: 0.84)
        static let secondaryText = Color(red: 0.72, green: 0.69, blue: 0.64)

        // Signals
        static let accent = Color(red: 0.79, green: 0.42, blue: 0.24)           // ~#C96A3D
        static let accentSoft = accent.opacity(0.18)
        static let support = Color(red: 0.36, green: 0.54, blue: 0.48)          // ~#5C8A7A
        static let success = Color(red: 0.31, green: 0.56, blue: 0.41)
        static let warning = Color(red: 0.82, green: 0.64, blue: 0.29)
        static let error = Color(red: 0.73, green: 0.30, blue: 0.27)
    }

    enum Metrics {
        static let cardCornerRadius: CGFloat = 12
        static let paperPanelCornerRadius: CGFloat = 14
        static let dropZoneCornerRadius: CGFloat = 16
        static let thumbnailCornerRadius: CGFloat = 6
        static let panelPadding: CGFloat = 16
        static let smallCornerRadius: CGFloat = 8
        static let cardBorderWidth: CGFloat = 1
        static let dropZoneBorderWidth: CGFloat = 1.5
        static let homePanelCornerRadius: CGFloat = 22
        static let homePanelHorizontalPadding: CGFloat = 40
    }

    enum Shadows {
        static let card = Color.black.opacity(0.28)
    }
}
