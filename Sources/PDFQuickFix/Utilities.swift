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

enum OCRSource: String, Hashable {
    case deepSeekOverlay
    case vision
    case none
}

struct PageProcessResult {
    var pageSizePoints: CGSize
    var cgImage: CGImage
    var textRunsInPoints: [RecognizedRun] // rects converted to points; only keep/replace
    var redactionRectCount: Int
    var suppressedOCRRunCount: Int
    var ocrSource: OCRSource
    var ocrRunCount: Int
    var deepSeekEligible: Bool
    var deepSeekSucceeded: Bool
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

enum DocumentInputKind {
    case pdf
    case image
}

func documentInputKind(for url: URL) -> DocumentInputKind? {
    guard url.isFileURL else { return nil }
    guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
    if type.conforms(to: .pdf) {
        return .pdf
    }
    if type.conforms(to: .png) || type.conforms(to: .jpeg) {
        return .image
    }
    return nil
}

func handleDocumentDrop(_ providers: [NSItemProvider],
                        allowedTypes: [UTType],
                        onResolvedURL: @escaping (URL) -> Void) -> Bool {
    func isAllowedURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return allowedTypes.contains { type.conforms(to: $0) }
    }

    func providerHasAllowedType(_ provider: NSItemProvider) -> Bool {
        for allowed in allowedTypes {
            if provider.hasItemConformingToTypeIdentifier(allowed.identifier) {
                return true
            }
        }
        return provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
    }

    guard let provider = providers.first(where: { providerHasAllowedType($0) }) else { return false }

    if provider.canLoadObject(ofClass: URL.self) {
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            if let url = url, isAllowedURL(url) {
                DispatchQueue.main.async {
                    onResolvedURL(url)
                }
            } else if let error = error {
                print("Drop loadObject failed: \(error)")
            }
        }
        return true
    }

    if let allowed = allowedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
        provider.loadFileRepresentation(forTypeIdentifier: allowed.identifier) { url, error in
            guard let url = url else { return }
            guard isAllowedURL(url) else { return }

            let tempDir = FileManager.default.temporaryDirectory
            let dst = tempDir.appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.copyItem(at: url, to: dst)

                DispatchQueue.main.async {
                    onResolvedURL(dst)
                }
            } catch {
                print("Failed to copy dropped file: \(error)")
            }
        }
        return true
    }

    return false
}

enum ImagePDFConverterError: LocalizedError {
    case invalidURL
    case unsupportedType
    case imageLoadFailed
    case pageCreationFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid image URL."
        case .unsupportedType:
            return "Only PNG or JPEG images are supported."
        case .imageLoadFailed:
            return "Failed to load the image."
        case .pageCreationFailed:
            return "Failed to create a PDF page from the image."
        case .writeFailed:
            return "Failed to write the PDF."
        }
    }
}

enum ImagePDFConverter {
    static func convertImageToPDF(at url: URL,
                                  outputURL: URL? = nil,
                                  preprocess: Bool = false,
                                  targetDPI: CGFloat? = nil) throws -> (url: URL, didPreprocess: Bool) {
        guard url.isFileURL else { throw ImagePDFConverterError.invalidURL }
        guard documentInputKind(for: url) == .image else {
            throw ImagePDFConverterError.unsupportedType
        }
        guard let image = NSImage(contentsOf: url) else {
            throw ImagePDFConverterError.imageLoadFailed
        }
        let preprocessResult = preprocess ? ImagePreprocessor.preprocess(image: image) : nil
        let processed = preprocessResult?.image ?? image
        let didPreprocess = preprocessResult?.didApply ?? false
        let sizedImage = resizedImageForTargetDPI(image: processed, targetDPI: targetDPI) ?? processed
        guard let page = PDFPage(image: sizedImage) else {
            throw ImagePDFConverterError.pageCreationFailed
        }

        let document = PDFDocument()
        document.insert(page, at: 0)

        let destination = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        guard document.write(to: destination) else {
            throw ImagePDFConverterError.writeFailed
        }
        return (destination, didPreprocess)
    }

    private static func resizedImageForTargetDPI(image: NSImage, targetDPI: CGFloat?) -> NSImage? {
        guard let targetDPI else { return nil }
        guard let cgImage = image.cgImage else { return nil }
        let widthPx = CGFloat(cgImage.width)
        let heightPx = CGFloat(cgImage.height)
        let sizePoints = CGSize(width: widthPx * 72.0 / targetDPI,
                                height: heightPx * 72.0 / targetDPI)
        return NSImage(cgImage: cgImage, size: sizePoints)
    }
}

enum ImagePreprocessor {
    private static let context = CIContext(options: nil)

    static func preprocess(image: NSImage) -> (image: NSImage, didApply: Bool)? {
        guard let cgImage = image.cgImage else { return nil }
        var didApply = false
        let baseCI = CIImage(cgImage: cgImage)
        let correctedCI: CIImage
        if let quad = detectDocumentQuad(in: cgImage),
           let corrected = applyPerspective(to: baseCI, quad: quad) {
            correctedCI = corrected
            didApply = true
        } else {
            correctedCI = baseCI
        }

        let enhanced = applyEnhancements(to: correctedCI)
        didApply = true

        guard let finalCG = context.createCGImage(enhanced, from: enhanced.extent) else {
            return (image, didApply)
        }
        let output = NSImage(cgImage: finalCG, size: NSSize(width: finalCG.width, height: finalCG.height))
        return (output, didApply)
    }

    private static func detectDocumentQuad(in cgImage: CGImage) -> VNRectangleObservation? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.6
        request.minimumSize = 0.2

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return request.results?.first
    }

    private static func applyPerspective(to image: CIImage,
                                         quad: VNRectangleObservation) -> CIImage? {
        let width = image.extent.width
        let height = image.extent.height

        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: normalized.x * width, y: normalized.y * height)
        }

        return image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: point(quad.topLeft)),
            "inputTopRight": CIVector(cgPoint: point(quad.topRight)),
            "inputBottomLeft": CIVector(cgPoint: point(quad.bottomLeft)),
            "inputBottomRight": CIVector(cgPoint: point(quad.bottomRight))
        ])
    }

    private static func applyEnhancements(to image: CIImage) -> CIImage {
        let grayscale = image.applyingFilter("CIColorControls", parameters: [
            "inputSaturation": 0.0,
            "inputContrast": 1.2,
            "inputBrightness": 0.0
        ])
        let shadow = grayscale.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputShadowAmount": 0.6,
            "inputHighlightAmount": 0.0
        ])
        let exposure = shadow.applyingFilter("CIExposureAdjust", parameters: [
            "inputEV": 0.2
        ])
        return exposure.applyingFilter("CIUnsharpMask", parameters: [
            "inputIntensity": 0.6,
            "inputRadius": 1.0
        ])
    }
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
