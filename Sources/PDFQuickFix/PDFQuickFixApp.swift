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
    }
}
