import SwiftUI
import PDFKit

struct OutlinePanel: View {
    @EnvironmentObject private var controller: StudioController
    @State private var newBookmarkTitle: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bookmarks")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("New bookmark title", text: $newBookmarkTitle)
                Button("Add") {
                    controller.addOutline(title: newBookmarkTitle)
                    newBookmarkTitle = ""
                }
                .disabled(controller.document == nil)
            }

            List {
                ForEach(controller.outlineRows) { row in
                    OutlineRowView(row: row,
                                   rename: controller.renameOutline,
                                   delete: controller.deleteOutline)
                }
            }
        }
        .padding()
    }
}

private struct OutlineRowView: View {
    @State private var title: String
    let row: OutlineRow
    let rename: (OutlineRow, String) -> Void
    let delete: (OutlineRow) -> Void

    init(row: OutlineRow,
         rename: @escaping (OutlineRow, String) -> Void,
         delete: @escaping (OutlineRow) -> Void) {
        self.row = row
        self.rename = rename
        self.delete = delete
        _title = State(initialValue: row.outline.label ?? "Untitled")
    }

    var body: some View {
        HStack {
            TextField("Untitled", text: $title, onCommit: {
                rename(row, title)
            })
            .textFieldStyle(.roundedBorder)
            .onAppear {
                title = row.outline.label ?? "Untitled"
            }
            .onChange(of: row.outline.label ?? "Untitled") { newValue in
                title = newValue
            }
            Spacer()
            Button {
                delete(row)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove bookmark")
        }
        .padding(.leading, CGFloat(row.depth) * 16)
    }
}

// MARK: - Reader Outline Components

struct ReaderOutlineNode: View {
    let node: PDFOutline
    let controller: ReaderControllerPro
    
    var body: some View {
        let count = node.numberOfChildren
        if count > 0 {
            let children = (0..<count).compactMap { node.child(at: $0) }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(children, id: \.self) { child in
                    ReaderOutlineRow(child: child, controller: controller)
                }
            }
        }
    }
}

struct ReaderOutlineRow: View {
    let child: PDFOutline
    let controller: ReaderControllerPro
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(child.label ?? "Untitled")
                .font(.caption)
                .padding(.leading, CGFloat(child.level) * 10)
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let dest = child.destination {
                        controller.pdfView?.go(to: dest)
                    }
                }
            // Recursive call
            ReaderOutlineNode(node: child, controller: controller)
        }
    }
}
