import AppKit
import SwiftUI

@MainActor
enum PDFQuickFixSharedState {
    static let aiSettings = LocalAISettings()
    static let aiInteractions = AIInteractionStore()
}

@MainActor
enum PDFQuickFixWindowKeeper {
    static var mainWindowController: NSWindowController?
}

enum AppLaunchWindowPolicy {
    static let mainWindowTitle = "PDFQuickFix"
    static let finderReceiptWindowTitle = "Finder Sanitize Receipt"

    enum FallbackTrigger {
        case initialLaunch
        case reopen
        case activation
    }

    static func shouldAllowDefaultReopen(hasUserFacingWindow: Bool) -> Bool {
        hasUserFacingWindow
    }

    static func shouldOpenFallbackWindow(hasUserFacingWindow: Bool,
                                         trigger: FallbackTrigger = .reopen) -> Bool
    {
        guard !hasUserFacingWindow else { return false }
        switch trigger {
        case .initialLaunch:
            return false
        case .reopen, .activation:
            return true
        }
    }

    static func isUserFacingWindow(title: String,
                                   isVisible: Bool,
                                   canBecomeMainOrKey: Bool,
                                   isMiniaturized: Bool = false) -> Bool
    {
        (isVisible || isMiniaturized) &&
            canBecomeMainOrKey &&
            (title == mainWindowTitle || title == finderReceiptWindowTitle)
    }
}

@main
struct PDFQuickFixApp: App {
    @NSApplicationDelegateAdaptor(PDFQuickFixAppDelegate.self) private var appDelegate
    @StateObject private var aiSettings = PDFQuickFixSharedState.aiSettings
    @StateObject private var aiInteractions = PDFQuickFixSharedState.aiInteractions

    init() {
        PDFKitWorkarounds.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
                .environmentObject(aiSettings)
                .environmentObject(aiInteractions)
        }
        .commands {
            AppCommands()
        }

        Settings {
            AISettingsView()
                .environmentObject(aiSettings)
                .environmentObject(aiInteractions)
        }

        Window("AI Activity", id: "ai-activity") {
            AIActivityView()
                .environmentObject(aiSettings)
                .environmentObject(aiInteractions)
        }
    }
}

final class PDFQuickFixAppDelegate: NSObject, NSApplicationDelegate {
    private let finderQuickActionService = FinderQuickActionService()

    @MainActor
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.servicesProvider = finderQuickActionService
        NSUpdateDynamicServices()
    }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        let hasUserFacingWindow = visibleUserWindow(in: sender) != nil
        guard AppLaunchWindowPolicy.shouldAllowDefaultReopen(hasUserFacingWindow: hasUserFacingWindow) else {
            openMainWindowIfNeeded(sender, activate: true)
            return false
        }
        return true
    }

    @MainActor
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let application = notification.object as? NSApplication else { return }
        openMainWindowIfNeeded(application, activate: false, trigger: .activation)
    }

    @MainActor
    private func openMainWindowIfNeeded(_ application: NSApplication,
                                        activate: Bool,
                                        trigger: AppLaunchWindowPolicy.FallbackTrigger = .reopen)
    {
        if let window = visibleUserWindow(in: application) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else if AppLaunchWindowPolicy.shouldOpenFallbackWindow(hasUserFacingWindow: false, trigger: trigger) {
            openFallbackMainWindow()
        }

        if activate {
            application.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    private func visibleUserWindow(in application: NSApplication) -> NSWindow? {
        application.windows.first { window in
            AppLaunchWindowPolicy.isUserFacingWindow(
                title: window.title,
                isVisible: window.isVisible,
                canBecomeMainOrKey: window.canBecomeMain || window.canBecomeKey,
                isMiniaturized: window.isMiniaturized
            )
        }
    }

    @MainActor
    private func openFallbackMainWindow() {
        if let existing = PDFQuickFixWindowKeeper.mainWindowController?.window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let rootView = ContentView()
            .frame(minWidth: 960, minHeight: 640)
            .environmentObject(PDFQuickFixSharedState.aiSettings)
            .environmentObject(PDFQuickFixSharedState.aiInteractions)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = AppLaunchWindowPolicy.mainWindowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.center()
        window.isReleasedWhenClosed = false
        PDFQuickFixWindowKeeper.mainWindowController = NSWindowController(window: window)
        PDFQuickFixWindowKeeper.mainWindowController?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

final class FinderQuickActionService: NSObject {
    @objc(sanitizeSelectedPDFs:userData:error:)
    func sanitizeSelectedPDFs(_ pasteboard: NSPasteboard,
                              userData _: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>)
    {
        let urls = FinderQuickActionSanitizer.pdfFileURLs(from: pasteboard)

        guard !urls.isEmpty else {
            error.pointee = "Select one or more PDF files in Finder."
            return
        }

        Task { @MainActor in
            FinderQuickActionCoordinator.shared.run(urls: urls)
        }
    }
}

// MARK: - Protocol & Key

@MainActor
protocol FileExportable: AnyObject {
    func saveDocument()
    func saveAs()
    func repairAndSaveAs()
    func printDocument()
    func exportToImages(format: NSBitmapImageRep.FileType)
    func exportToText()
    func exportOptimized()
    func exportMetadataCleaned()
    func exportFlattened()
    func exportEncrypted()
    func exportSanitized()
}

struct FileExportableKey: FocusedValueKey {
    typealias Value = FileExportable
}

@MainActor
protocol DocumentPrintable: AnyObject {
    var hasPrintableDocument: Bool { get }
    func printDocument()
}

struct DocumentPrintableKey: FocusedValueKey {
    typealias Value = DocumentPrintable
}

extension FocusedValues {
    var fileExportable: FileExportable? {
        get { self[FileExportableKey.self] }
        set { self[FileExportableKey.self] = newValue }
    }

    var documentPrintable: DocumentPrintable? {
        get { self[DocumentPrintableKey.self] }
        set { self[DocumentPrintableKey.self] = newValue }
    }

    var pdfActionable: PDFActionable? {
        get { self[PDFActionableKey.self] }
        set { self[PDFActionableKey.self] = newValue }
    }

    var studioToolSwitchable: StudioToolSwitchable? {
        get { self[StudioToolSwitchableKey.self] }
        set { self[StudioToolSwitchableKey.self] = newValue }
    }

    var documentClosable: DocumentClosable? {
        get { self[DocumentClosableKey.self] }
        set { self[DocumentClosableKey.self] = newValue }
    }

    var documentHealthPresentable: DocumentHealthPresentable? {
        get { self[DocumentHealthPresentableKey.self] }
        set { self[DocumentHealthPresentableKey.self] = newValue }
    }

    var documentUndoable: DocumentUndoable? {
        get { self[DocumentUndoableKey.self] }
        set { self[DocumentUndoableKey.self] = newValue }
    }

    var selectedTextReplaceable: SelectedTextReplaceable? {
        get { self[SelectedTextReplaceableKey.self] }
        set { self[SelectedTextReplaceableKey.self] = newValue }
    }
}

// MARK: - New Protocols

@MainActor
protocol PDFActionable: AnyObject {
    func zoomIn()
    func zoomOut()
    func rotateLeft()
    func rotateRight()
}

struct PDFActionableKey: FocusedValueKey {
    typealias Value = PDFActionable
}

@MainActor
protocol StudioToolSwitchable: AnyObject {
    var selectedTool: StudioTool { get set }
}

struct StudioToolSwitchableKey: FocusedValueKey {
    typealias Value = StudioToolSwitchable
}

@MainActor
protocol DocumentClosable: AnyObject {
    func closeDocument()
}

struct DocumentClosableKey: FocusedValueKey {
    typealias Value = DocumentClosable
}

@MainActor
protocol DocumentHealthPresentable: AnyObject {
    var canShowDocumentHealth: Bool { get }
    func showDocumentHealth()
}

struct DocumentHealthPresentableKey: FocusedValueKey {
    typealias Value = DocumentHealthPresentable
}

@MainActor
protocol DocumentUndoable: AnyObject {
    func undoLastEdit()
    func redoLastEdit()
}

struct DocumentUndoableKey: FocusedValueKey {
    typealias Value = DocumentUndoable
}

@MainActor
protocol SelectedTextReplaceable: AnyObject {
    var canReplaceSelectedText: Bool { get }
    func replaceSelectedTextWithPrompt()
    func redactSelectedTextWithConfirmation()
}

struct SelectedTextReplaceableKey: FocusedValueKey {
    typealias Value = SelectedTextReplaceable
}

// MARK: - Commands

struct AppCommands: Commands {
    @FocusedValue(\.fileExportable) var fileExportable
    @FocusedValue(\.documentPrintable) var documentPrintable
    @FocusedValue(\.pdfActionable) var pdfActionable
    @FocusedValue(\.studioToolSwitchable) var studioToolSwitchable
    @FocusedValue(\.documentClosable) var documentClosable
    @FocusedValue(\.documentHealthPresentable) var documentHealthPresentable
    @FocusedValue(\.documentUndoable) var documentUndoable
    @FocusedValue(\.selectedTextReplaceable) var selectedTextReplaceable
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .undoRedo) {
            Divider()
            Button("Undo PDF Edit") {
                documentUndoable?.undoLastEdit()
            }
            .disabled(documentUndoable == nil)

            Button("Redo PDF Edit") {
                documentUndoable?.redoLastEdit()
            }
            .disabled(documentUndoable == nil)
        }

        CommandGroup(after: .newItem) {
            Button("Close Document") {
                documentClosable?.closeDocument()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(documentClosable == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                fileExportable?.saveDocument()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(fileExportable == nil)

            Button("Save As…") {
                fileExportable?.saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(fileExportable == nil)

            Button("Repair & Save As…") {
                fileExportable?.repairAndSaveAs()
            }
            .disabled(fileExportable == nil)

            Menu("Export") {
                Menu("Images") {
                    Button("JPEG") { fileExportable?.exportToImages(format: .jpeg) }
                    Button("PNG") { fileExportable?.exportToImages(format: .png) }
                    Button("TIFF") { fileExportable?.exportToImages(format: .tiff) }
                }

                Button("Text") {
                    fileExportable?.exportToText()
                }

                Button("Optimized PDF…") {
                    fileExportable?.exportOptimized()
                }

                Button("Metadata-Clean PDF…") {
                    fileExportable?.exportMetadataCleaned()
                }

                Button("Flattened PDF…") {
                    fileExportable?.exportFlattened()
                }

                Button("Encrypted PDF…") {
                    fileExportable?.exportEncrypted()
                }

                Divider()

                Button("Sanitize for Sharing…") {
                    fileExportable?.exportSanitized()
                }
            }
            .disabled(fileExportable == nil)

            // Batch operations - always available
            Divider()

            Button("Sanitize Folder…") {
                BatchSanitizeCoordinator.shared.showBatchSanitizePanel()
            }
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                if let documentPrintable, documentPrintable.hasPrintableDocument {
                    documentPrintable.printDocument()
                } else if !PrintDispatcher.printActivePDFDocument(source: "cmdp-dispatcher") {
                    DocumentPrintService.presentUnavailableAlert()
                }
            }
            .keyboardShortcut("p", modifiers: .command)
        }

        CommandMenu("View") {
            Button("Document Health…") {
                documentHealthPresentable?.showDocumentHealth()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(documentHealthPresentable?.canShowDocumentHealth != true)

            Divider()

            Button("Zoom In") {
                pdfActionable?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(pdfActionable == nil)

            Button("Zoom Out") {
                pdfActionable?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(pdfActionable == nil)

            Divider()

            Button("Rotate Left") {
                pdfActionable?.rotateLeft()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(pdfActionable == nil)

            Button("Rotate Right") {
                pdfActionable?.rotateRight()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(pdfActionable == nil)
        }

        CommandMenu("Tools") {
            Button("Replace Selected Text…") {
                selectedTextReplaceable?.replaceSelectedTextWithPrompt()
            }
            .disabled(selectedTextReplaceable?.canReplaceSelectedText != true)

            Button("Redact Selected Text…") {
                selectedTextReplaceable?.redactSelectedTextWithConfirmation()
            }
            .disabled(selectedTextReplaceable?.canReplaceSelectedText != true)

            Divider()

            ForEach(StudioTool.allCases) { tool in
                Button(tool.rawValue) {
                    studioToolSwitchable?.selectedTool = tool
                }
                .disabled(studioToolSwitchable == nil)
                // Note: Menu bar items don't support "checked" state easily with SwiftUI Commands yet without custom binding logic,
                // but this will allow switching tools.
            }
        }

        CommandMenu("AI") {
            Button("AI Activity…") {
                openWindow(id: "ai-activity")
            }
        }
    }
}
