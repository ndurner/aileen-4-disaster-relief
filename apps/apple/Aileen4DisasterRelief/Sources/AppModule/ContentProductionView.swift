import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentProductionView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ProductionWorkflowViewModel()
    @State private var fileImporterPresented = false
    @State private var shareSheetPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Inputs") {
                    Picker("Output", selection: $viewModel.outputKind) {
                        Text("Image").tag(ProductionWorkflowViewModel.OutputKind.image)
                        Text("Reel").tag(ProductionWorkflowViewModel.OutputKind.reel)
                    }
                    .pickerStyle(.segmented)

                    TextField("Story", text: $appState.story, axis: .vertical)
                        .lineLimit(4...8)

                    PhotosPicker(
                        selection: $viewModel.selectedPhotoItems,
                        maxSelectionCount: 10,
                        matching: .any(of: [.images, .videos]),
                        preferredItemEncoding: .current
                    ) {
                        Label("Add from Camera Roll", systemImage: "photo.on.rectangle")
                    }

                    Button("Add from Files") {
                        fileImporterPresented = true
                    }
                }

                if !viewModel.assets.isEmpty {
                    Section("Media assets") {
                        ForEach(viewModel.assets) { asset in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(asset.displayName)
                                Text(asset.kind == .image ? "Image asset" : "Video asset")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Production") {
                    Button(viewModel.isRunning ? "Producing..." : "Produce visuals + post body") {
                        Task {
                            await viewModel.run(
                                backgroundBriefing: appState.backgroundBriefing,
                                story: appState.story,
                                visualModel: appState.selectedProductionModel,
                                textModel: appState.selectedTextModel,
                                modelSource: appState.preferredModelSource
                            )
                        }
                    }
                    .disabled(viewModel.isRunning)
                }

                if !viewModel.productionSummary.isEmpty {
                    Section("Visual production summary") {
                        Text(viewModel.productionSummary)
                    }
                }

                if !viewModel.postBodyText.isEmpty {
                    Section("Post body") {
                        Text(viewModel.postBodyText)
                        Button(ProcessInfo.processInfo.isiOSAppOnMac ? "Export results" : "Share results") {
                            if ProcessInfo.processInfo.isiOSAppOnMac {
                                viewModel.openExportDirectory()
                            } else {
                                shareSheetPresented = true
                            }
                        }
                    }
                }

                if let latestError = viewModel.latestError {
                    Section("Error") {
                        Text(latestError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Content production")
            .task(id: viewModel.selectedPhotoItems) {
                guard !viewModel.selectedPhotoItems.isEmpty else { return }
                await viewModel.ingestPhotos()
            }
            .fileImporter(
                isPresented: $fileImporterPresented,
                allowedContentTypes: [.image, .movie],
                allowsMultipleSelection: true
            ) { result in
                do {
                    let urls = try result.get()
                    for url in urls {
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessing { url.stopAccessingSecurityScopedResource() }
                        }
                        try viewModel.appendImportedFile(url, displayName: viewModel.importedFileDisplayName(for: url))
                    }
                } catch {
                    viewModel.latestError = error.localizedDescription
                }
            }
            .sheet(isPresented: $shareSheetPresented) {
                ShareSheet(items: viewModel.shareItems)
            }
        }
    }
}
