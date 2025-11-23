import AppKit
import PDFKit
import Vision
import CoreGraphics
import CoreText
import SwiftUI
import UniformTypeIdentifiers

extension NSImage {
    var cgImage: CGImage? {
        var proposedRect = CGRect(origin: .zero, size: self.size)
        return self.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }
}

func visionRectToPixelRect(_ bb: CGRect, imageSize: CGSize) -> CGRect {
    // Vision uses normalized coords with origin at bottom-left
    let x = bb.origin.x * imageSize.width
    let y = (1 - bb.origin.y - bb.size.height) * imageSize.height
    let w = bb.size.width * imageSize.width
    let h = bb.size.height * imageSize.height
    return CGRect(x: x, y: y, width: w, height: h)
}

func pixelsToPoints(_ px: CGFloat, dpi: CGFloat) -> CGFloat {
    return px * 72.0 / dpi
}

func pointsToPixels(_ pt: CGFloat, dpi: CGFloat) -> CGFloat {
    return pt * dpi / 72.0
}

struct RecognizedRun {
    enum Kind {
        case keep(String)
        case replace(String)
        case skip // redacted
    }
    var kind: Kind
    var rectInPixels: CGRect
}

struct PageProcessResult {
    var pageSizePoints: CGSize
    var cgImage: CGImage
    var textRunsInPoints: [RecognizedRun] // rects converted to points; only keep/replace
}

// MARK: - Design System

enum AppColors {
    static let primary = Color.accentColor
    static let secondary = Color.secondary
    static let background = Color(NSColor.windowBackgroundColor)
    static let surface = Color(NSColor.controlBackgroundColor)
    static let surfaceSecondary = Color(NSColor.controlBackgroundColor).opacity(0.5)
    static let border = Color(NSColor.separatorColor)
    
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    
    static let gradientStart = Color.accentColor.opacity(0.1)
    static let gradientEnd = Color.accentColor.opacity(0.05)
}

enum AppLayout {
    static let padding: CGFloat = 16
    static let cornerRadius: CGFloat = 12
    static let smallCornerRadius: CGFloat = 8
}

// MARK: - View Modifiers

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AppLayout.padding)
            .background(AppColors.surface)
            .cornerRadius(AppLayout.cornerRadius)
            .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
            .overlay(
                RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                    .stroke(AppColors.border, lineWidth: 0.5)
            )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var isDisabled: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(isDisabled ? Color.gray.opacity(0.3) : AppColors.primary)
            .foregroundColor(.white)
            .cornerRadius(AppLayout.smallCornerRadius)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .shadow(color: AppColors.primary.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(AppColors.surface)
            .foregroundColor(.primary)
            .cornerRadius(AppLayout.smallCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                    .stroke(AppColors.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? AppColors.surfaceSecondary : Color.clear)
            .foregroundColor(.primary)
            .cornerRadius(AppLayout.smallCornerRadius)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Extensions

extension View {
    func cardStyle() -> some View {
        modifier(CardModifier())
    }
    
    func appFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        self.font(.system(style, design: .rounded).weight(weight))
    }
}

/// Resolve a dropped PDF URL from the provided item providers. Returns `false` when no PDF-like item was found.
func handlePDFDrop(_ providers: [NSItemProvider], onResolvedURL: @escaping (URL) -> Void) -> Bool {
    let identifiers = [
        UTType.fileURL.identifier,
        UTType.url.identifier,
        UTType.pdf.identifier,
        UTType.item.identifier,
        UTType.data.identifier,
        UTType.content.identifier
    ]

    var finished = false

    func finish(with url: URL?) {
        guard !finished else { return }
        guard let url, url.pathExtension.lowercased() == "pdf" else { return }
        finished = true
        DispatchQueue.main.async {
            onResolvedURL(url)
        }
    }

    guard !providers.isEmpty else { return false }

    for provider in providers {
        for identifier in identifiers {
            // Prefer an in-place URL, then a temporary representation from a file promise, and finally a data payload.
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: identifier) { url, _, _ in
                finish(with: url)
            }

            provider.loadFileRepresentation(forTypeIdentifier: identifier) { tempURL, _ in
                finish(with: tempURL)
            }

            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    finish(with: url)
                } else if let data = item as? Data {
                    finish(with: URL(dataRepresentation: data, relativeTo: nil))
                } else if let nsurl = item as? NSURL {
                    finish(with: nsurl as URL)
                }
            }

            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                guard let data else { return }
                finish(with: URL(dataRepresentation: data, relativeTo: nil))
            }
        }
    }

    return true
}

struct FullscreenPDFDropView: View {
    let onResolvedURL: (URL) -> Void

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL, .url, .pdf], delegate: PDFURLDropDelegate(onResolvedURL: onResolvedURL))
            .ignoresSafeArea()
            .zIndex(1)
    }
}

struct PDFURLDropDelegate: DropDelegate {
    let onResolvedURL: (URL) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.pdf, .fileURL, .url])
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.pdf, .fileURL, .url])
        return handlePDFDrop(providers, onResolvedURL: onResolvedURL)
    }
}
