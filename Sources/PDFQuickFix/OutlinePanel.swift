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

            if controller.isMassiveDocument && controller.outlineRows.isEmpty {
                Text("Outline loads when opened for very large documents.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .onAppear {
            controller.loadOutlineIfNeeded()
        }
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
    @State private var isExpanded: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                // Chevron for expansion
                if child.numberOfChildren > 0 {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        }
                } else {
                    Spacer().frame(width: 16, height: 16)
                }
                
                Text(child.label ?? "Untitled")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let dest = child.destination {
                            controller.pdfView?.go(to: dest)
                        }
                    }
            }
            .padding(.leading, CGFloat(child.level) * 16)
            .padding(.vertical, 4)
            .padding(.trailing, 4)
            .background(
                Rectangle()
                    .fill(Color.primary.opacity(0.0001)) // For full row hit testing if needed, though mostly covered by components
            )

            // Recursive call for children
            if isExpanded {
                ReaderOutlineNode(node: child, controller: controller)
            }
        }
    }
}
