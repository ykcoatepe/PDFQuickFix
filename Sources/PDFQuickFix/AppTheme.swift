import SwiftUI

/// Centralized palette and layout metrics shared across PDFQuickFix surfaces.
/// Values are aligned with the current Reader facelift so other modules can
/// reuse the same look without duplicating constants.
enum AppTheme {
    enum Colors {
        // Core surfaces
        static let background = Color(red: 0.06, green: 0.07, blue: 0.07) // ~#0F1113
        static let sidebarBackground = Color(red: 0.09, green: 0.10, blue: 0.12)
        static let cardBackground = Color(red: 0.13, green: 0.15, blue: 0.17) // ~#22262B
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
        static let accent = Color(red: 0.79, green: 0.42, blue: 0.24) // ~#C96A3D
        static let accentSoft = accent.opacity(0.18)
        static let support = Color(red: 0.36, green: 0.54, blue: 0.48) // ~#5C8A7A
        static let success = Color(red: 0.31, green: 0.56, blue: 0.41)
        static let warning = Color(red: 0.82, green: 0.64, blue: 0.29)
        static let error = Color(red: 0.73, green: 0.30, blue: 0.27)

        /// Warm off-white for labels sitting on top of the vermilion accent.
        /// Per DESIGN.md "avoid pure white on pure black"; ~#F4F0E8 paper white.
        static let onAccent = Color(red: 0.957, green: 0.941, blue: 0.910)
    }

    /// Type scale from DESIGN.md. SF Pro Display/Text is selected automatically
    /// by `design: .default` based on point size; SF Mono via `.monospaced`.
    /// Line-height guidance from the scale is documented per token; SwiftUI Font
    /// does not encode line height, so apply `.lineSpacing` at call sites when needed.
    enum Typography {
        /// Display XL — 28 / 32. First-run heroes and top-level workbench titles.
        static let displayXL = Font.system(size: 28, weight: .bold, design: .default)
        /// Display L — 24 / 28. Prominent empty-state and mode headers.
        static let displayL = Font.system(size: 24, weight: .bold, design: .default)
        /// Title — 20 / 24. Workbench and section titles.
        static let title = Font.system(size: 20, weight: .semibold, design: .default)
        /// Section — 15 / 20 semibold. Section headers, control labels, chips.
        static let section = Font.system(size: 15, weight: .semibold, design: .default)
        /// Body — 13 / 18. Descriptions and supporting copy.
        static let body = Font.system(size: 13, weight: .regular, design: .default)
        /// Body Small — 12 / 16. Compact labels and secondary copy.
        static let bodySmall = Font.system(size: 12, weight: .regular, design: .default)
        /// Meta / Caption — 11 / 14. Metadata and captions.
        static let caption = Font.system(size: 11, weight: .regular, design: .default)
        /// Mono Small — 11 / 14. Logs, metrics, and validation output.
        static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
    }

    enum Metrics {
        // Corner radii snapped to the DESIGN.md scale: small 8 / medium 12 / large 18 / hero 24.
        static let cardCornerRadius: CGFloat = 12 // medium
        static let paperPanelCornerRadius: CGFloat = 12 // medium (was 14)
        static let dropZoneCornerRadius: CGFloat = 18 // large (was 16)
        static let thumbnailCornerRadius: CGFloat = 8 // small (was 6)
        static let panelPadding: CGFloat = 16
        static let smallCornerRadius: CGFloat = 8 // small
        static let largeCornerRadius: CGFloat = 18 // large
        static let cardBorderWidth: CGFloat = 1
        static let dropZoneBorderWidth: CGFloat = 1.5
        static let homePanelCornerRadius: CGFloat = 24 // hero (was 22)
        static let homePanelHorizontalPadding: CGFloat = 40
    }

    /// Motion tokens from DESIGN.md: micro 80ms, short 160ms, medium 240ms, long 360ms.
    /// Easings: easeOut for enter, easeInOut for panel shifts, easeIn for dismiss.
    enum Motion {
        static let micro: Double = 0.08
        static let short: Double = 0.16
        static let medium: Double = 0.24
        static let long: Double = 0.36

        /// Enter transitions (appearing content, presses). easeOut.
        static let enter = Animation.easeOut(duration: short)
        /// Panel shifts (sidebars, inspectors, workbench swaps). easeInOut.
        static let panelShift = Animation.easeInOut(duration: medium)
        /// Dismiss transitions (disappearing content). easeIn.
        static let dismiss = Animation.easeIn(duration: short)
        /// Tight press feedback on interactive controls. easeInOut micro.
        static let press = Animation.easeInOut(duration: micro)
    }

    enum Shadows {
        static let card = Color.black.opacity(0.28)
    }
}
