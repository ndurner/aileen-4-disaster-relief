import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentProductionView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ProductionWorkflowViewModel()
    @State private var fileImporterPresented = false
    @State private var shareSheetPresented = false
    @State private var productionTask: Task<Void, Never>?
    @State private var updateDetailsExpanded = false

    private var cloudModeNeedsAPIKey: Bool {
        appState.productionExecutionMode == .field && appState.inferenceMode == .cloud && !appState.hasGoogleAIStudioAPIKey
    }

    private var productionStatusDetail: String {
        if viewModel.isRunning {
            return viewModel.currentStatusDetail ?? "Working"
        }
        if hasIssue {
            return "Needs attention"
        }
        if cloudModeNeedsAPIKey {
            return "Gemini API key required"
        }
        if viewModel.assets.isEmpty {
            return "Add media first"
        }
        if appState.productionExecutionMode == .desk {
            return viewModel.deskHandoffReady ? "Package ready" : "Ready to package"
        }
        if hasFieldResults {
            return "Ready to retry"
        }
        return appState.inferenceMode == .cloud ? "Cloud ready" : "On-device ready"
    }

    private var hasProducedResults: Bool {
        !viewModel.producedURLs.isEmpty || !viewModel.postBodyText.isEmpty
    }

    private var hasFieldResults: Bool {
        appState.productionExecutionMode == .field && hasProducedResults
    }

    private var hasDeskHandoffReady: Bool {
        appState.productionExecutionMode == .desk && viewModel.deskHandoffReady
    }

    private var hasShareableResults: Bool {
        hasFieldResults || hasDeskHandoffReady
    }

    private var hasIssue: Bool {
        viewModel.latestError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var resultsTitle: String {
        hasIssue ? "Partial results" : "Results"
    }

    private var resultsDetail: String {
        if hasIssue {
            if !viewModel.producedURLs.isEmpty && viewModel.postBodyText.isEmpty {
                return "Visual only"
            }
            if viewModel.producedURLs.isEmpty && !viewModel.postBodyText.isEmpty {
                return "Text only"
            }
            return "Incomplete"
        }
        if hasDeskHandoffReady {
            return "Originals ready"
        }
        return viewModel.producedURLs.isEmpty ? "Text only" : "Ready to export"
    }

    private var canStartProduction: Bool {
        !viewModel.assets.isEmpty && !viewModel.isRunning && !cloudModeNeedsAPIKey
    }

    private var selectedMediaIncludesVideo: Bool {
        viewModel.assets.contains { $0.kind == .movie }
    }

    private var productionButtonTitle: String {
        if viewModel.isRunning {
            return appState.productionExecutionMode == .desk ? "Preparing package..." : "Building the update..."
        }
        if hasIssue {
            return appState.productionExecutionMode == .desk ? "Retry package" : "Retry production"
        }
        if hasShareableResults {
            if appState.productionExecutionMode == .desk {
                return "Rebuild package"
            }
            return "Redo production"
        }
        return appState.productionExecutionMode == .desk ? "Package for desk" : "Produce visuals and post body"
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

                updateDetailsSection

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
                    Text("Cloud creation is selected. Add your API key in Settings before producing visuals and caption text.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if appState.productionExecutionMode == .desk {
                    Text("Desk Mode keeps the story and original media unchanged so someone else can finish the post later.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if appState.productionExecutionMode == .desk && selectedMediaIncludesVideo {
                    Text("Video needs broadband handoff. For satellite messenger sharing, use still photos and the copied package text.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.coral)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    let retry = appState.productionExecutionMode == .field && hasProducedResults
                    productionTask = Task {
                        await viewModel.run(
                            backgroundBriefing: appState.backgroundBriefing,
                            story: appState.story,
                            executionMode: appState.productionExecutionMode,
                            inference: appState.inferenceConfiguration,
                            retry: retry
                        )
                        productionTask = nil
                    }
                } label: {
                    HStack(spacing: 10) {
                        if viewModel.isRunning {
                            ProgressView()
                                .tint(.white)
                        } else if hasShareableResults {
                            Image(systemName: "arrow.clockwise")
                        } else if appState.productionExecutionMode == .desk {
                            Image(systemName: "shippingbox")
                        } else {
                            Image(systemName: "sparkles")
                        }

                        Text(productionButtonTitle)
                    }
                }
                .buttonStyle(OceanPrimaryButtonStyle())
                .disabled(!canStartProduction)

                if viewModel.isRunning {
                    Button {
                        productionTask?.cancel()
                        productionTask = nil
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle")
                            Text("Cancel production")
                        }
                    }
                    .buttonStyle(OceanSecondaryButtonStyle())
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

            if appState.productionExecutionMode == .field && !viewModel.postBodyText.isEmpty {
                OceanCard {
                    OceanSectionHeader(title: "Post body")

                    Text(viewModel.postBodyText)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if hasShareableResults {
                OceanCard {
                    OceanSectionHeader(
                        title: resultsTitle,
                        detail: resultsDetail
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

    private var updateDetailsSection: some View {
        DisclosureGroup(isExpanded: $updateDetailsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                metadataModeControl(
                    title: "Location",
                    selection: $viewModel.fieldUpdateDetails.locationMode,
                    summary: viewModel.locationMetadataSummary
                )

                if viewModel.fieldUpdateDetails.locationMode == .manual {
                    detailField(
                        title: "Public location label",
                        placeholder: "A broad region, town, coast, or response area",
                        text: $viewModel.fieldUpdateDetails.manualLocationLabel
                    )
                }

                metadataModeControl(
                    title: "Update time",
                    selection: $viewModel.fieldUpdateDetails.updateTimeMode,
                    summary: viewModel.updateTimeMetadataSummary
                )

                if viewModel.fieldUpdateDetails.updateTimeMode == .manual {
                    detailField(
                        title: "Local update time",
                        placeholder: "Today afternoon, 4 Apr 2026 15:30, or similar",
                        text: $viewModel.fieldUpdateDetails.manualUpdateTimeLocal
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Safety note")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(OceanPalette.ink)

                    OceanTextEditor(
                        text: $viewModel.fieldUpdateDetails.safetyWarning,
                        placeholder: "Anything that should limit what gets published.",
                        minHeight: 112
                    )
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "location.magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(OceanPalette.deepWater)

                Text("Location, time, and safety")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(OceanPalette.ink)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.46))
        )
    }

    private func metadataModeControl(
        title: String,
        selection: Binding<ProductionWorkflowViewModel.FieldUpdateDetails.MetadataFieldMode>,
        summary: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(OceanPalette.ink)

            Picker(title, selection: selection) {
                ForEach(ProductionWorkflowViewModel.FieldUpdateDetails.MetadataFieldMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(summary)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailField(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(OceanPalette.ink)

            TextField(placeholder, text: text)
                .textInputAutocapitalization(.sentences)
                .autocorrectionDisabled(false)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.58))
                )
        }
    }

    @ViewBuilder
    private var shareActions: some View {
        Button(shareButtonTitle) {
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
        .disabled(!hasShareableResults)

        if appState.productionExecutionMode == .field {
            Button(viewModel.postBodyText.isEmpty ? "No text yet" : "Copy text") {
                if !viewModel.postBodyText.isEmpty {
                    viewModel.copyPostBodyToPasteboard()
                }
            }
            .buttonStyle(OceanSecondaryButtonStyle())
            .disabled(viewModel.postBodyText.isEmpty)
        }
    }

    private var shareButtonTitle: String {
        if hasIssue {
            return ProcessInfo.processInfo.isiOSAppOnMac ? "Export partial results" : "Share partial results"
        }
        if hasDeskHandoffReady {
            return ProcessInfo.processInfo.isiOSAppOnMac ? "Export package" : "Share package"
        }
        return ProcessInfo.processInfo.isiOSAppOnMac ? "Export results" : "Share results"
    }
}
