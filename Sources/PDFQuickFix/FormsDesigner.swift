import PDFKit
import SwiftUI

struct FormsDesigner: View {
    @EnvironmentObject private var controller: StudioController
    @State private var selectedKind: FormFieldKind = .text
    @State private var fieldName: String = ""
    @State private var choiceOptions: String = "Option 1, Option 2"
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
            .pickerStyle(.menu)

            TextField("Field name", text: $fieldName)

            if selectedKind.usesOptions {
                TextField("Options, comma separated", text: $choiceOptions)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Stepper("Width \(Int(width)) pt", value: $width, in: 80 ... 320, step: 10)
                Stepper("Height \(Int(height)) pt", value: $height, in: 20 ... 120, step: 4)
            }

            Button {
                addField()
            } label: {
                Label("Insert Field", systemImage: "plus")
            }
            .disabled(controller.document == nil)

            Divider()

            HStack {
                Text("Existing Fields")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(controller.formFieldRows.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if controller.formFieldRows.isEmpty {
                Text("No form fields on this file")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                List {
                    ForEach(controller.formFieldRows) { row in
                        FormFieldRow(row: row,
                                     focus: controller.focus,
                                     delete: controller.delete)
                    }
                }
                .frame(minHeight: 160)
            }
        }
        .padding()
        .onAppear {
            controller.loadAnnotationsIfNeeded()
        }
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
                                rect: rect,
                                options: parsedOptions)
    }

    private var parsedOptions: [String] {
        choiceOptions
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct FormFieldRow: View {
    let row: AnnotationRow
    let focus: (AnnotationRow) -> Void
    let delete: (AnnotationRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.annotation.fieldName?.isEmpty == false ? row.annotation.fieldName ?? "Field" : "Unnamed field")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Page \(row.pageIndex + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(fieldKind)
                .font(.caption)
                .foregroundStyle(.secondary)

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

    private var fieldKind: String {
        switch row.annotation.widgetFieldType {
        case .text:
            "Text field"
        case .button:
            row.annotation.widgetControlType == .radioSafe ? "Radio button" : "Checkbox"
        case .signature:
            "Signature field"
        case .choice:
            row.annotation.isListChoice ? "List field" : "Dropdown field"
        default:
            "Form field"
        }
    }
}

struct SignatureDesigner: View {
    @EnvironmentObject private var controller: StudioController
    @State private var signatureImage: NSImage? = SignatureStore.load()
    @State private var stampWidth: Double = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Signature")
                .font(.headline)

            SignatureCaptureView(image: $signatureImage)

            if let signatureImage {
                Image(nsImage: signatureImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 72)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
                    )

                Stepper("Width \(Int(stampWidth)) pt", value: $stampWidth, in: 80 ... 360, step: 10)

                Button {
                    controller.addSignatureStamp(image: signatureImage, width: CGFloat(stampWidth))
                } label: {
                    Label("Place Signature", systemImage: "signature")
                }
                .disabled(controller.document == nil)
            } else {
                Text("Draw and save a signature before placing it on the current page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}
