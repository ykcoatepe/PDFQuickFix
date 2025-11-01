import SwiftUI
import PDFKit

struct FormsDesigner: View {
    @EnvironmentObject private var controller: StudioController
    @State private var selectedKind: FormFieldKind = .text
    @State private var fieldName: String = ""
    @State private var width: Double = 160
    @State private var height: Double = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Form Fields")
                .font(.headline)

            Picker("Kind", selection: $selectedKind) {
                ForEach(FormFieldKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            TextField("Field name", text: $fieldName)

            HStack {
                Stepper("Width \(Int(width)) pt", value: $width, in: 80...320, step: 10)
                Stepper("Height \(Int(height)) pt", value: $height, in: 20...120, step: 4)
            }

            Button {
                addField()
            } label: {
                Label("Insert Field", systemImage: "plus")
            }
            .disabled(controller.document == nil)

            Spacer()

            Text("Fields are placed at the center of the visible page. Adjust position inside the PDF reader after insertion.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func addField() {
        guard let page = controller.pdfView?.currentPage else { return }
        let bounds = page.bounds(for: .mediaBox)
        let rect = CGRect(x: bounds.midX - CGFloat(width) / 2,
                          y: bounds.midY - CGFloat(height) / 2,
                          width: CGFloat(width),
                          height: CGFloat(height))
        controller.addFormField(kind: selectedKind,
                                name: fieldName,
                                rect: rect)
    }
}
