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
    // Vision uses normalized coords with origin at bottom-left (same direction as Core Graphics user space)
    let x = bb.origin.x * imageSize.width
    let y = bb.origin.y * imageSize.height
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
    var rect: CGRect
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
    guard let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) ||
        $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
        $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    }) else { return false }

    // 1. Try to load as a simple URL (Best for Finder drops)
    if provider.canLoadObject(ofClass: URL.self) {
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            if let url = url {
                // Determine if it's a file URL and if it looks like a PDF
                // For Finder drops, it's usually a file URL.
                DispatchQueue.main.async {
                    onResolvedURL(url)
                }
            } else if let error = error {
                print("Drop loadObject failed: \(error)")
            }
        }
        return true
    }

    // 2. Fallback: Try loading file representation (works for some apps that don't vend a URL object directly)
    if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
        provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
            guard let url = url else { return }
            
            // Accessing the URL is only valid within this block for file representations.
            // Copy it to a safe temporary location.
            let tempDir = FileManager.default.temporaryDirectory
            let dst = tempDir.appendingPathComponent(url.lastPathComponent)
            do {
                // If it exists, remove it
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: url, to: dst)
                
                DispatchQueue.main.async {
                    onResolvedURL(dst)
                }
            } catch {
                print("Failed to copy dropped PDF: \(error)")
            }
        }
        return true
    }
    
    return false
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

extension Animation {
    /// Standard transition for sidebars (Left/Right panels)
    static var sidebarTransition: Animation {
        .easeOut(duration: 0.25)
    }
    
    /// Standard transition for smaller panels or overlays
    static var panelTransition: Animation {
        .easeOut(duration: 0.2)
    }
}

// MARK: - Visual Effect Helper

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - PDF Thumbnail Helper

struct PDFThumbnailViewRepresentable: NSViewRepresentable {
    let pdfView: PDFView
    
    func makeNSView(context: Context) -> PDFThumbnailView {
        let thumbnailView = PDFThumbnailView()
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = CGSize(width: 60, height: 80)

        thumbnailView.backgroundColor = NSColor.controlBackgroundColor
        return thumbnailView
    }
    
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        nsView.pdfView = pdfView
    }
}
