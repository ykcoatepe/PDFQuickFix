import AppKit
import PDFKit
import SwiftUI

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

            if controller.isMassiveDocument, controller.annotationRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Annotation evidence loads on demand for very large documents.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Load annotations") {
                        controller.loadAnnotationsIfNeeded()
                    }
                    .disabled(controller.document == nil)
                }
            }

            TextField("Filter comments", text: $filterText)
                .textFieldStyle(.roundedBorder)

            if filteredAnnotations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.annotationRows.isEmpty ? "No annotations on this file" : "No annotations match this filter")
                        .font(.subheadline.weight(.semibold))
                    Text(controller.annotationRows.isEmpty
                        ? "Comments, highlights, and note annotations will appear here when the PDF contains them."
                        : "Try a broader search to review the notes already captured in this document.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
            } else {
                List {
                    ForEach(filteredAnnotations) { row in
                        CommentRow(row: row,
                                   focus: controller.focus,
                                   edit: controller.editAnnotation(_:draft:),
                                   delete: controller.delete)
                    }
                }
            }
        }
        .padding()
        .onAppear {
            controller.loadAnnotationsIfNeeded()
        }
    }
}

private struct CommentRow: View {
    let row: AnnotationRow
    let focus: (AnnotationRow) -> Void
    let edit: (AnnotationRow, AnnotationEditDraft) -> Void
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
                Button {
                    if let draft = promptForAnnotationEdit(row) {
                        edit(row, draft)
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
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

    private func promptForAnnotationEdit(_ row: AnnotationRow) -> AnnotationEditDraft? {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading

        let field = NSTextField(string: row.annotation.contents ?? "")
        field.placeholderString = "Annotation text"
        field.frame = CGRect(x: 0, y: 0, width: 340, height: 24)
        stack.addArrangedSubview(field)

        var urlField: NSTextField?
        if row.annotation.url != nil || row.annotation.type == PDFAnnotationSubtype.link.rawValue {
            let field = NSTextField(string: row.annotation.url?.absoluteString ?? "")
            field.placeholderString = "https://example.com"
            field.frame = CGRect(x: 0, y: 0, width: 340, height: 24)
            urlField = field
            stack.addArrangedSubview(field)
        }

        let alert = NSAlert()
        alert.messageText = "Edit Annotation"
        alert.informativeText = "Update the note, markup text, or link target for this annotation."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return AnnotationEditDraft(contents: field.stringValue, urlString: urlField?.stringValue)
    }
}
