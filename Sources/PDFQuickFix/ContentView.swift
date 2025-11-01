import SwiftUI
import AppKit

struct ContentView: View {
    var body: some View {
        TabView {
            QuickFixTab()
                .tabItem { Label("QuickFix", systemImage: "wand.and.rays") }
            ReaderTabView()
                .tabItem { Label("Reader", systemImage: "doc.richtext") }
        }
        .frame(minWidth: 960, minHeight: 640)
    }
}
