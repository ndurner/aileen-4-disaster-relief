import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentProductionView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ProductionWorkflowViewModel()
    @State private var fileImporterPresented = false
    @State private var shareSheetPresented = false

    var body: some View {
        OceanScreen {
            AileenWorkflowCard(
                    imageName: "AileenProductionScene",
                    title: "Build the next update",
                    message: "Give me the angle, format, and media to build the next post.",
                    bandMidOpacity: 0.56,
                    bandBottomOpacity: 0.93
                ) {

                Picker("Output", selection: $viewModel.outputKind) {
                    Text("Image").tag(ProductionWorkflowViewModel.OutputKind.image)
                    Text("Reel").tag(ProductionWorkflowViewModel.OutputKind.reel)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Story prompt")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(OceanPalette.ink)

                    OceanTextEditor(
                        text: $appState.story,
                        placeholder: "Describe the update, the location, and the information people need to act on.",
                        minHeight: 170
                    )
                }

                VStack(spacing: 12) {
                    PhotosPicker(
                        selection: $viewModel.selectedPhotoItems,
                        maxSelectionCount: 10,
                        matching: .any(of: [.images, .videos]),
                        preferredItemEncoding: .current
                    ) {
                        OceanActionTile(
                            title: "Add from Camera Roll",
                            subtitle: "Pull in photos or short clips already on the device.",
                            symbol: "photo.on.rectangle.angled"
                        )
                    }

                    Button {
                        fileImporterPresented = true
                    } label: {
                        OceanActionTile(
                            title: "Add from Files",
                            subtitle: "Bring in media you have stored elsewhere on the device.",
                            symbol: "square.and.arrow.down"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !viewModel.assets.isEmpty {
                OceanCard {
                    OceanSectionHeader(
                        title: "Selected media",
                        detail: "\(viewModel.assets.count) asset\(viewModel.assets.count == 1 ? "" : "s")"
                    )

                    VStack(spacing: 12) {
                        ForEach(viewModel.assets) { asset in
                            HStack(spacing: 14) {
                                Image(systemName: asset.kind == .image ? "photo" : "film")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(OceanPalette.deepWater)
                                    .frame(width: 38, height: 38)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(OceanPalette.tideFoam)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(asset.displayName)
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                        .foregroundStyle(OceanPalette.ink)

                                    Text(asset.kind == .image ? "Image asset" : "Video asset")
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(OceanPalette.ink.opacity(0.60))
                                }

                                Spacer()
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .fill(Color.white.opacity(0.52))
                            )
                        }
                    }
                }
            }

            OceanCard {
                OceanSectionHeader(title: "Production", detail: viewModel.isRunning ? "Working" : "Ready")

                Button {
                    Task {
                        await viewModel.run(
                            backgroundBriefing: appState.backgroundBriefing,
                            story: appState.story,
                            visualModel: appState.selectedProductionModel,
                            textModel: appState.selectedTextModel,
                            modelSource: appState.preferredModelSource
                        )
                    }
                } label: {
                    HStack(spacing: 10) {
                        if viewModel.isRunning {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "sparkles")
                        }

                        Text(viewModel.isRunning ? "Building the update..." : "Produce visuals and post body")
                    }
                }
                .buttonStyle(OceanPrimaryButtonStyle())
                .disabled(viewModel.isRunning)
            }

            if !viewModel.productionSummary.isEmpty {
                OceanCard {
                    OceanSectionHeader(title: "Visual production summary")

                    Text(viewModel.productionSummary)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !viewModel.postBodyText.isEmpty {
                OceanCard {
                    OceanSectionHeader(title: "Post body")

                    Text(viewModel.postBodyText)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    ViewThatFits {
                        HStack(spacing: 12) {
                            shareActions
                        }

                        VStack(spacing: 12) {
                            shareActions
                        }
                    }
                }
            }

            if let latestError = viewModel.latestError {
                OceanCard {
                    OceanSectionHeader(title: "Issue", detail: "Needs attention")

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.orange)

                        Text(latestError)
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(OceanPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
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

    @ViewBuilder
    private var shareActions: some View {
        Button(ProcessInfo.processInfo.isiOSAppOnMac ? "Export results" : "Share results") {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                viewModel.openExportDirectory()
            } else {
                shareSheetPresented = true
            }
        }
        .buttonStyle(OceanSecondaryButtonStyle())

        Button("Copy text") {
            viewModel.copyPostBodyToPasteboard()
        }
        .buttonStyle(OceanSecondaryButtonStyle())
    }
}
