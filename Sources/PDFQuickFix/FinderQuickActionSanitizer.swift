import AppKit
import Foundation
import PDFKit
@preconcurrency import PDFQuickFixKit
import SwiftUI
import UniformTypeIdentifiers

struct FinderSanitizeOutcome {
    let review: CleanupReview?
    let reviewErrorDescription: String?
}

enum FinderQuickActionSanitizer {
    static let serviceMenuTitle = "PDFQuickFix/Sanitize PDF for Sharing"
    static let outputSuffix = "-sanitized"

    static func pdfFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []

        if let readURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [
                .urlReadingFileURLsOnly: true,
                .urlReadingContentsConformToTypes: [UTType.pdf.identifier],
            ]
        ) as? [URL] {
            urls.append(contentsOf: readURLs)
        }

        if let fileNames = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
            urls.append(contentsOf: fileNames.map { URL(fileURLWithPath: $0) })
        }

        if let fileURLString = pasteboard.string(forType: .fileURL),
           let url = URL(string: fileURLString)
        {
            urls.append(url)
        }

        var seen = Set<String>()
        return urls
            .filter { $0.isFileURL && $0.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame }
            .filter { url in
                let key = url.standardizedFileURL.path
                return seen.insert(key).inserted
            }
    }

    static func outputURL(for sourceURL: URL, fileManager: FileManager = .default) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension.isEmpty ? "pdf" : sourceURL.pathExtension

        var candidate = directory
            .appendingPathComponent("\(baseName)\(outputSuffix)")
            .appendingPathExtension(fileExtension)

        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(baseName)\(outputSuffix)-\(index)")
                .appendingPathExtension(fileExtension)
            index += 1
        }

        return candidate
    }

    static func sanitizeFile(sourceURL: URL,
                             outputURL: URL,
                             profile: SanitizeProfile,
                             progress: PDFDocumentSanitizer.ProgressHandler? = nil) throws -> FinderSanitizeOutcome
    {
        let evidenceSourceData = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard let document = PDFDocument(data: evidenceSourceData) else {
            throw PDFDocumentSanitizerError.unableToOpen(sourceURL)
        }

        let sanitized = try PDFDocumentSanitizer.sanitize(
            document: document,
            sourceURL: sourceURL,
            options: PDFDocumentSanitizer.Options.from(profile: profile),
            progress: progress
        )

        guard sanitized.write(to: outputURL) else {
            throw NSError(
                domain: "PDFQuickFix.FinderQuickAction",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write \(outputURL.lastPathComponent)."]
            )
        }

        do {
            let review = try CleanupReviewBuilder.build(
                sourceData: evidenceSourceData,
                sourceFileName: sourceURL.lastPathComponent,
                outputURL: outputURL,
                profile: profile
            )
            return FinderSanitizeOutcome(review: review, reviewErrorDescription: nil)
        } catch {
            return FinderSanitizeOutcome(
                review: nil,
                reviewErrorDescription: error.localizedDescription
            )
        }
    }
}

struct FinderQuickActionResult: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let outputURL: URL?
    let errorDescription: String?
    let review: CleanupReview?
    let reviewErrorDescription: String?

    init(sourceURL: URL,
         outputURL: URL?,
         errorDescription: String?,
         review: CleanupReview? = nil,
         reviewErrorDescription: String? = nil)
    {
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.errorDescription = errorDescription
        self.review = review
        self.reviewErrorDescription = reviewErrorDescription
    }

    var succeeded: Bool {
        outputURL != nil && errorDescription == nil
    }
}

@MainActor
final class FinderQuickActionCoordinator: ObservableObject {
    static let shared = FinderQuickActionCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var profile: SanitizeProfile = .privacyClean
    @Published private(set) var processedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var currentFileName: String?
    @Published private(set) var results: [FinderQuickActionResult] = []

    private var windowController: FinderQuickActionWindowController?
    private var receiptIsVisible = false

    private init() {}

    func run(urls: [URL]) {
        if isRunning {
            showReceipt()
            return
        }

        let pdfURLs = urls
            .filter { $0.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame }
            .map(\.standardizedFileURL)

        guard !pdfURLs.isEmpty else {
            isRunning = false
            processedCount = 0
            totalCount = 0
            currentFileName = nil
            results = [
                FinderQuickActionResult(
                    sourceURL: URL(fileURLWithPath: "/"),
                    outputURL: nil,
                    errorDescription: "Select one or more PDF files in Finder."
                ),
            ]
            showReceipt()
            return
        }

        profile = SanitizeDefaults.shared.defaultProfile
        isRunning = true
        processedCount = 0
        totalCount = pdfURLs.count
        currentFileName = pdfURLs.first?.lastPathComponent
        results = []
        showReceipt()

        let selectedProfile = profile
        DispatchQueue.global(qos: .userInitiated).async {
            var completed: [FinderQuickActionResult] = []

            for sourceURL in pdfURLs {
                DispatchQueue.main.async {
                    self.currentFileName = sourceURL.lastPathComponent
                }

                let access = SecurityScopedAccess(url: sourceURL)
                defer { access.stopAccess() }

                do {
                    let outputURL = FinderQuickActionSanitizer.outputURL(for: sourceURL)
                    let outcome = try FinderQuickActionSanitizer.sanitizeFile(
                        sourceURL: sourceURL,
                        outputURL: outputURL,
                        profile: selectedProfile
                    )
                    completed.append(
                        FinderQuickActionResult(
                            sourceURL: sourceURL,
                            outputURL: outputURL,
                            errorDescription: nil,
                            review: outcome.review,
                            reviewErrorDescription: outcome.reviewErrorDescription
                        )
                    )
                } catch {
                    completed.append(
                        FinderQuickActionResult(
                            sourceURL: sourceURL,
                            outputURL: nil,
                            errorDescription: error.localizedDescription
                        )
                    )
                }

                let snapshot = completed
                DispatchQueue.main.async {
                    self.processedCount = snapshot.count
                    if self.receiptIsVisible {
                        self.results = snapshot
                    }
                }
            }

            DispatchQueue.main.async {
                self.isRunning = false
                self.currentFileName = nil
                if self.receiptIsVisible {
                    self.results = completed
                }
                let outputURLs = completed.compactMap(\.outputURL)
                if !outputURLs.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NSWorkspace.shared.activateFileViewerSelecting(outputURLs)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            self.windowController?.window?.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
                    }
                }
            }
        }
    }

    private func showReceipt() {
        receiptIsVisible = true
        if let existing = windowController {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = FinderQuickActionWindowController(coordinator: self)
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)

        controller.onClose = { [weak self] in
            self?.receiptIsVisible = false
            self?.results = []
            self?.windowController = nil
        }
    }
}

final class FinderQuickActionWindowController: NSWindowController {
    var onClose: (() -> Void)?
    private var closeObserver: NSObjectProtocol?

    convenience init(coordinator: FinderQuickActionCoordinator) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Finder Sanitize Receipt"
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)

        window.contentView = NSHostingView(
            rootView: FinderQuickActionReceiptView(coordinator: coordinator)
        )

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onClose?()
        }
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }
}

struct FinderQuickActionReceiptView: View {
    @ObservedObject var coordinator: FinderQuickActionCoordinator
    @State private var selectedReview: CleanupReview?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            progress
            results
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .background(AppTheme.Colors.background)
        .sheet(item: $selectedReview) { review in
            CleanupExportReviewSheet(review: review)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Finder handoff received", systemImage: "checkmark.shield")
                .font(.title3.weight(.semibold))
                .foregroundColor(AppTheme.Colors.primaryText)

            Text("PDFQuickFix is creating local outbound copies with your saved sanitize profile. Originals stay untouched.")
                .font(.subheadline)
                .foregroundColor(AppTheme.Colors.secondaryText)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: Double(coordinator.processedCount), total: Double(max(coordinator.totalCount, 1)))
                .tint(AppTheme.Colors.accent)

            HStack {
                Text("\(coordinator.processedCount)/\(coordinator.totalCount) files")
                Spacer()
                Text(profileLabel(coordinator.profile))
            }
            .font(.caption)
            .foregroundColor(AppTheme.Colors.secondaryText)

            if let currentFileName = coordinator.currentFileName, coordinator.isRunning {
                Text("Sanitizing \(currentFileName)")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
        }
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(coordinator.results) { result in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(result.succeeded ? AppTheme.Colors.success : AppTheme.Colors.warning)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.sourceURL.lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(AppTheme.Colors.primaryText)

                            if let outputURL = result.outputURL {
                                Text("Outbound copy: \(outputURL.lastPathComponent)")
                                    .font(.caption)
                                    .foregroundColor(AppTheme.Colors.secondaryText)

                                if let review = result.review {
                                    HStack(spacing: 8) {
                                        Label(
                                            evidenceVerdictTitle(review.evidence.verdict),
                                            systemImage: evidenceVerdictIcon(review.evidence.verdict)
                                        )
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(evidenceVerdictColor(review.evidence.verdict))

                                        Button("Review Cleanup") {
                                            selectedReview = review
                                        }
                                        .buttonStyle(.link)
                                    }
                                } else if let reviewError = result.reviewErrorDescription {
                                    Label("Cleanup review unavailable: \(reviewError)", systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.Colors.warning)
                                }
                            } else if let error = result.errorDescription {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(AppTheme.Colors.secondaryText)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(AppTheme.Colors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius))
                }
            }
        }
    }

    private func profileLabel(_ profile: SanitizeProfile) -> String {
        switch profile {
        case .privacyClean:
            "Privacy Clean"
        case .lightClean:
            "Light Clean"
        case .keepEditable:
            "Keep Editable"
        }
    }

    private func evidenceVerdictTitle(_ verdict: CleanupEvidenceVerdict) -> String {
        switch verdict {
        case .passed: "Passed"
        case .reviewRequired: "Review required"
        case .failed: "Failed"
        }
    }

    private func evidenceVerdictIcon(_ verdict: CleanupEvidenceVerdict) -> String {
        switch verdict {
        case .passed: "checkmark.shield.fill"
        case .reviewRequired: "exclamationmark.triangle.fill"
        case .failed: "xmark.shield.fill"
        }
    }

    private func evidenceVerdictColor(_ verdict: CleanupEvidenceVerdict) -> Color {
        switch verdict {
        case .passed: AppTheme.Colors.success
        case .reviewRequired: AppTheme.Colors.warning
        case .failed: AppTheme.Colors.error
        }
    }
}
