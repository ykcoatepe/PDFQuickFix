import SwiftUI

@main
struct PDFQuickFixApp: App {
    init() {
        PDFKitWorkarounds.install()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            AppCommands()
        }
    }
}

// MARK: - Protocol & Key

@MainActor
protocol FileExportable: AnyObject {
    func saveAs()
    func repairAndSaveAs()
    func exportToImages(format: NSBitmapImageRep.FileType)
    func exportToText()
    func exportSanitized()
}

struct FileExportableKey: FocusedValueKey {
    typealias Value = FileExportable
}

extension FocusedValues {
    var fileExportable: FileExportable? {
        get { self[FileExportableKey.self] }
        set { self[FileExportableKey.self] = newValue }
    }
    
    var pdfActionable: PDFActionable? {
        get { self[PDFActionableKey.self] }
        set { self[PDFActionableKey.self] = newValue }
    }
    
    var studioToolSwitchable: StudioToolSwitchable? {
        get { self[StudioToolSwitchableKey.self] }
        set { self[StudioToolSwitchableKey.self] = newValue }
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

// MARK: - Commands

struct AppCommands: Commands {
    @FocusedValue(\.fileExportable) var fileExportable
    @FocusedValue(\.pdfActionable) var pdfActionable
    @FocusedValue(\.studioToolSwitchable) var studioToolSwitchable
    
    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Save As…") {
                fileExportable?.saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
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
        }
        
        CommandMenu("View") {
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
    }
}
