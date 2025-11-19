import SwiftUI
import PDFKit
import UniformTypeIdentifiers

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

            ZStack {
                List(selection: $controller.selectedPageIDs) {
                    ForEach(controller.pageSnapshots) { snapshot in
                        HStack(alignment: .center, spacing: 12) {
                            Image(decorative: snapshot.thumbnail, scale: 1, orientation: .up)
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
                        .onDrag {
                            let provider = NSItemProvider()
                            provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                                                 visibility: .all) { completion in
                                let payload = Data("\(snapshot.index)".utf8)
                                completion(payload, nil)
                                return nil
                            }
                            return provider
                        }
                        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                            guard let provider = providers.first else { return false }
                            provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                                guard let data,
                                      let string = String(data: data, encoding: .utf8),
                                      let sourceIndex = Int(string) else { return }
                                DispatchQueue.main.async {
                                    controller.movePage(at: sourceIndex, to: snapshot.index)
                                }
                            }
                            return true
                        }
                    }
                }

                if controller.pageSnapshots.isEmpty && !controller.isThumbnailsLoading {
                    Text("No pages to show.")
                        .foregroundStyle(.secondary)
                        .padding()
                        .allowsHitTesting(false)
                }

                if controller.isThumbnailsLoading {
                    ZStack {
                        Color.black.opacity(0.05)
                        LoadingOverlayView(status: "Rendering thumbnails…")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
            }
        }
        .padding()
    }
}
