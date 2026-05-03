import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentProductionView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ProductionWorkflowViewModel()
    @State private var fileImporterPresented = false
    @State private var shareSheetPresented = false

    private var cloudModeNeedsAPIKey: Bool {
        appState.inferenceMode == .cloud && !appState.hasGoogleAIStudioAPIKey
    }

    private var productionStatusDetail: String {
        if viewModel.isRunning {
            return "Working"
        }
        if cloudModeNeedsAPIKey {
            return "Google AI Studio key required"
        }
        if viewModel.assets.isEmpty {
            return "Add media first"
        }
        if hasProducedResults {
            return "Ready to retry"
        }
        return appState.inferenceMode == .cloud ? "Cloud ready" : "On-device ready"
    }

    private var hasProducedResults: Bool {
        !viewModel.producedURLs.isEmpty || !viewModel.postBodyText.isEmpty
    }

    private var canStartProduction: Bool {
        !viewModel.assets.isEmpty && !viewModel.isRunning && !cloudModeNeedsAPIKey
    }

    private var productionButtonTitle: String {
        if viewModel.isRunning {
            return "Building the update..."
        }
        if hasProducedResults {
            return "Redo production"
        }
        return "Produce visuals and post body"
    }

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

                                Button {
                                    viewModel.removeAsset(asset)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(.red.opacity(0.82))
                                        .frame(width: 38, height: 38)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(Color.white.opacity(0.62))
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.isRunning)
                                .accessibilityLabel("Remove \(asset.displayName)")
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
                OceanSectionHeader(title: "Production", detail: productionStatusDetail)

                if cloudModeNeedsAPIKey {
                    Text("Cloud inference is selected. Add your Google AI Studio API key in Settings before producing visuals and caption text.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    let retry = hasProducedResults
                    Task {
                        await viewModel.run(
                            backgroundBriefing: appState.backgroundBriefing,
                            story: appState.story,
                            inference: appState.inferenceConfiguration,
                            retry: retry
                        )
                    }
                } label: {
                    HStack(spacing: 10) {
                        if viewModel.isRunning {
                            ProgressView()
                                .tint(.white)
                        } else if hasProducedResults {
                            Image(systemName: "arrow.clockwise")
                        } else {
                            Image(systemName: "sparkles")
                        }

                        Text(productionButtonTitle)
                    }
                }
                .buttonStyle(OceanPrimaryButtonStyle())
                .disabled(!canStartProduction)
            }

            if !viewModel.postBodyText.isEmpty {
                OceanCard {
                    OceanSectionHeader(title: "Post body")

                    Text(viewModel.postBodyText)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if hasProducedResults {
                OceanCard {
                    OceanSectionHeader(
                        title: "Results",
                        detail: viewModel.producedURLs.isEmpty ? "Text only" : "Ready to export"
                    )

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
                    try viewModel.appendImportedFile(
                        url,
                        displayName: viewModel.importedFileDisplayName(for: url),
                        importSource: .importedFile
                    )
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
                do {
                    try viewModel.prepareSharePackage()
                    shareSheetPresented = true
                } catch {
                    viewModel.latestError = error.localizedDescription
                }
            }
        }
        .buttonStyle(OceanSecondaryButtonStyle())
        .disabled(viewModel.producedURLs.isEmpty && viewModel.postBodyText.isEmpty)

        Button(viewModel.postBodyText.isEmpty ? "No text yet" : "Copy text") {
            if !viewModel.postBodyText.isEmpty {
                viewModel.copyPostBodyToPasteboard()
            }
        }
        .buttonStyle(OceanSecondaryButtonStyle())
        .disabled(viewModel.postBodyText.isEmpty)
    }
}
