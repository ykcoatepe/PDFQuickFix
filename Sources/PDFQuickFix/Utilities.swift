import AppKit
import PDFKit
import Vision
import CoreGraphics
import CoreText
import SwiftUI
import UniformTypeIdentifiers
import Security

enum QuickFixOutputSelectionError: Error {
    case cancelled
}

struct QuickFixOutputSelection {
    let url: URL
    let access: SecurityScopedAccess?
}

struct OutputDirectoryBookmark: Codable {
    let path: String
    var bookmark: Data
}

final class OutputDirectoryAccessStore {
    static let shared = OutputDirectoryAccessStore()

    private let storageKey = "QuickFix.OutputDirectoryBookmarks"
    private let bookmarking: Bookmarking
    private let defaults: UserDefaults
    private var cached: [OutputDirectoryBookmark] = []

    init(bookmarking: Bookmarking = SystemBookmarking(), defaults: UserDefaults = .standard) {
        self.bookmarking = bookmarking
        self.defaults = defaults
        load()
    }

    var count: Int {
        cached.count
    }

    func access(for directory: URL) -> SecurityScopedAccess? {
        let normalizedPath = directory.standardizedFileURL.path
        guard let index = cached.firstIndex(where: { $0.path == normalizedPath }) else {
            return nil
        }
        do {
            let result = try bookmarking.resolveBookmarkData(
                cached[index].bookmark,
                options: .withSecurityScope,
                relativeTo: nil
            )
            if result.isStale,
               let updated = try? bookmarking.bookmarkData(for: result.url,
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil) {
                cached[index].bookmark = updated
                save()
            }
            return SecurityScopedAccess(url: result.url)
        } catch {
            return nil
        }
    }

    func store(directory: URL) {
        let normalizedPath = directory.standardizedFileURL.path
        do {
            let data = try bookmarking.bookmarkData(for: directory,
                                                    includingResourceValuesForKeys: nil,
                                                    relativeTo: nil)
            if let index = cached.firstIndex(where: { $0.path == normalizedPath }) {
                cached[index].bookmark = data
            } else {
                cached.append(OutputDirectoryBookmark(path: normalizedPath, bookmark: data))
            }
            save()
        } catch {
            return
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cached) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([OutputDirectoryBookmark].self, from: data) else {
            cached = []
            return
        }
        cached = decoded
    }

    func clear() {
        cached.removeAll()
        defaults.removeObject(forKey: storageKey)
    }
}

@MainActor
func resolveQuickFixOutputSelection(defaultOutputURL: URL,
                                    preferredOutputURL: URL? = nil,
                                    panelTitle: String = "Save QuickFix Output") throws -> QuickFixOutputSelection {
    let effectiveURL = preferredOutputURL ?? defaultOutputURL
    let directoryURL = effectiveURL.deletingLastPathComponent()
    let fileManager = FileManager.default
    let directoryWritable = fileManager.isWritableFile(atPath: directoryURL.path)
    let fileExists = fileManager.fileExists(atPath: effectiveURL.path)
    let fileWritable = fileManager.isWritableFile(atPath: effectiveURL.path)

    if directoryWritable && (!fileExists || fileWritable) {
        return QuickFixOutputSelection(url: effectiveURL, access: nil)
    }

    if let access = OutputDirectoryAccessStore.shared.access(for: directoryURL) {
        let directoryWritableWithAccess = fileManager.isWritableFile(atPath: directoryURL.path)
        let fileWritableWithAccess = fileManager.isWritableFile(atPath: effectiveURL.path)
        if directoryWritableWithAccess && (!fileExists || fileWritableWithAccess) {
            return QuickFixOutputSelection(url: effectiveURL, access: access)
        }
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.title = panelTitle
    panel.nameFieldStringValue = effectiveURL.lastPathComponent
    panel.directoryURL = directoryURL

    if panel.runModal() == .OK, let url = panel.url {
        let outputDirectory = url.deletingLastPathComponent()
        OutputDirectoryAccessStore.shared.store(directory: outputDirectory)
        let access = OutputDirectoryAccessStore.shared.access(for: outputDirectory)
        return QuickFixOutputSelection(url: url, access: access)
    }
    throw QuickFixOutputSelectionError.cancelled
}

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
    case localOCR
    case cloudOCR
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
    var localOCREligible: Bool
    var localOCRSucceeded: Bool
}

// MARK: - Design System

// MARK: - View Modifiers

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AppTheme.Metrics.panelPadding)
            .background(AppTheme.Colors.cardBackground)
            .cornerRadius(AppTheme.Metrics.cardCornerRadius)
            .shadow(color: AppTheme.Shadows.card.opacity(0.7), radius: 6, x: 0, y: 3)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius)
                    .stroke(AppTheme.Colors.cardBorder, lineWidth: 0.5)
            )
    }
}

struct PaperPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AppTheme.Metrics.panelPadding)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Metrics.paperPanelCornerRadius, style: .continuous)
                    .fill(AppTheme.Colors.paperBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Metrics.paperPanelCornerRadius, style: .continuous)
                    .stroke(AppTheme.Colors.paperBorder, lineWidth: 1)
            )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var isDisabled: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(isDisabled ? Color.gray.opacity(0.3) : AppTheme.Colors.accent)
            .foregroundColor(.white)
            .cornerRadius(AppTheme.Metrics.smallCornerRadius)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .shadow(color: AppTheme.Colors.accent.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(AppTheme.Colors.cardBackground)
            .foregroundColor(AppTheme.Colors.primaryText)
            .cornerRadius(AppTheme.Metrics.smallCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius)
                    .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
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
            .background(configuration.isPressed ? AppTheme.Colors.elevatedBackground : Color.clear)
            .foregroundColor(AppTheme.Colors.primaryText)
            .cornerRadius(AppTheme.Metrics.smallCornerRadius)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Extensions

extension View {
    func cardStyle() -> some View {
        modifier(CardModifier())
    }

    func paperPanelStyle() -> some View {
        modifier(PaperPanelModifier())
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

// MARK: - Keychain Helper

enum KeychainStore {
    static func get(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(service: String, account: String, value: String?) {
        if value == nil || value?.isEmpty == true {
            delete(service: service, account: account)
            return
        }
        let data = value?.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
