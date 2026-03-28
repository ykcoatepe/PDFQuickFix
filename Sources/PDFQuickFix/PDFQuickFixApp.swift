import SwiftUI

@main
struct PDFQuickFixApp: App {
    @StateObject private var aiSettings = LocalAISettings()
    @StateObject private var aiInteractions = AIInteractionStore()

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

// MARK: - Protocol & Key

@MainActor
protocol FileExportable: AnyObject {
    func saveAs()
    func repairAndSaveAs()
    func printDocument()
    func exportToImages(format: NSBitmapImageRep.FileType)
    func exportToText()
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

// MARK: - Commands

struct AppCommands: Commands {
    @FocusedValue(\.fileExportable) var fileExportable
    @FocusedValue(\.documentPrintable) var documentPrintable
    @FocusedValue(\.pdfActionable) var pdfActionable
    @FocusedValue(\.studioToolSwitchable) var studioToolSwitchable
    @FocusedValue(\.documentClosable) var documentClosable
    @FocusedValue(\.documentHealthPresentable) var documentHealthPresentable
    @Environment(\.openWindow) private var openWindow
    
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Close Document") {
                documentClosable?.closeDocument()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(documentClosable == nil)
        }
        
        CommandGroup(after: .saveItem) {
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
