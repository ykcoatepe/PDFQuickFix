import SwiftUI
import PDFKit

struct CommentsPanel: View {
    @EnvironmentObject private var controller: StudioController
    @State private var filterText: String = ""

    var filteredAnnotations: [AnnotationRow] {
        if filterText.isEmpty { return controller.annotationRows }
        return controller.annotationRows.filter { row in
            let title = row.title.lowercased()
            let contents = row.annotation.contents?.lowercased() ?? ""
            let query = filterText.lowercased()
            return title.contains(query) || contents.contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Annotations")
                .font(.headline)

            TextField("Filter comments", text: $filterText)
                .textFieldStyle(.roundedBorder)

            List {
                ForEach(filteredAnnotations) { row in
                    CommentRow(row: row,
                               focus: controller.focus,
                               delete: controller.delete)
                }
            }
        }
        .padding()
    }
}

private struct CommentRow: View {
    let row: AnnotationRow
    let focus: (AnnotationRow) -> Void
    let delete: (AnnotationRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.title)
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text("Page \(row.pageIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let contents = row.annotation.contents, !contents.isEmpty {
                Text(contents)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    focus(row)
                } label: {
                    Label("Go to", systemImage: "arrow.right.circle")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                Button(role: .destructive) {
                    delete(row)
                } label: {
                    Label("Remove", systemImage: "trash")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
