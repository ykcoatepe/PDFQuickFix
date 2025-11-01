import SwiftUI
import PDFKit

struct PageOrganizerView: View {
    @EnvironmentObject private var controller: StudioController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pages")
                    .font(.headline)
                Spacer()
                Button("Duplicate") {
                    controller.duplicateSelectedPages()
                }
                .disabled(controller.selectedPageIDs.isEmpty)
                Button("Export…") {
                    controller.exportSelectedPages()
                }
                .disabled(controller.selectedPageIDs.isEmpty)
                Button(role: .destructive) {
                    controller.deleteSelectedPages()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .labelStyle(.titleOnly)
                }
                .disabled(controller.selectedPageIDs.isEmpty)
            }

            List(selection: $controller.selectedPageIDs) {
                ForEach(controller.pageSnapshots) { snapshot in
                    HStack(alignment: .center, spacing: 12) {
                        Image(nsImage: snapshot.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 60, height: 80)
                            .cornerRadius(4)
                            .shadow(radius: 1, y: 1)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.label)
                                .font(.subheadline)
                                .bold()
                            Text("Index \(snapshot.index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            controller.movePage(at: snapshot.index, to: snapshot.index - 1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(snapshot.index == 0)
                        .help("Move up")

                        Button {
                            controller.movePage(at: snapshot.index, to: snapshot.index + 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(snapshot.index >= controller.pageSnapshots.count - 1)
                        .help("Move down")

                        Button {
                            controller.goTo(page: snapshot.index)
                        } label: {
                            Image(systemName: "arrow.right")
                        }
                        .buttonStyle(.borderless)
                        .help("Jump to page")
                    }
                    .tag(snapshot.id)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
    }
}
