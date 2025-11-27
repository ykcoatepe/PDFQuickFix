import SwiftUI
import AppKit

struct ContentView: View {
    @State private var currentMode: AppMode = .reader
    @StateObject private var documentHub = SharedDocumentHub()
    @StateObject private var readerController = ReaderControllerPro()
    
    var body: some View {
        ZStack {
            switch currentMode {
            case .reader:
                ReaderProView(controller: readerController, selectedTab: $currentMode)
            case .quickFix:
                QuickFixTab()
            case .studio:
                StudioView(selectedTab: $currentMode)
            case .split:
                SplitView(selectedTab: $currentMode)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .environmentObject(documentHub)
    }
}

enum AppMode: String, CaseIterable, Identifiable {
    case reader = "Reader"
    case quickFix = "Quick Fix"
    case studio = "Studio"
    case split = "Split"
    
    var id: String { rawValue }
}

struct AppModeSwitcher: View {
    @Binding var currentMode: AppMode
    var modes: [AppMode] = AppMode.switcherModes
    
    var body: some View {
        Picker("", selection: $currentMode) {
            ForEach(modes) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 260)
    }
}

extension AppMode {
    /// Modes shown in the top segmented control (Quick Fix handled elsewhere).
    static let switcherModes: [AppMode] = [.reader, .studio, .split]
}

// Shared document coordinator so Reader can hand off the current file to Studio.
final class SharedDocumentHub: ObservableObject {
    enum Source { case reader, studio }

    @Published private(set) var currentURL: URL?
    @Published private(set) var lastSource: Source?
    @Published var syncEnabled: Bool = true

    func update(url: URL?, from source: Source) {
        if currentURL != url {
            currentURL = url
        }
        lastSource = source
    }
}
