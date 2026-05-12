import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var modelDownloadStore = ModelDownloadStore()
    @State private var importPickerPresented = false
    @State private var importError: String?
    @State private var revealsCloudAPIKey = false

    private let modelLocator = ModelLocator()

    var body: some View {
        OceanScreen {
            AileenWorkflowCard(
                    imageName: "AileenSettingsScene",
                    title: "Choose how I work",
                    message: "Create the post now or prepare it for a teammate to finish later."
                ) {
                productionExecutionModePicker

                processingLocationPicker

                if appState.productionExecutionMode == .field {
                    if appState.inferenceMode == .onDevice {
                        onDeviceModelPicker(title: "Visual model", selection: $appState.selectedProductionModel)
                        onDeviceModelPicker(title: "Post body model", selection: $appState.selectedTextModel)
                    } else {
                        cloudModelPicker(title: "Visual model", selection: $appState.selectedCloudProductionModel)
                        cloudModelPicker(title: "Post body model", selection: $appState.selectedCloudTextModel)
                    }
                }
            }

            if appState.productionExecutionMode == .field {
                if appState.inferenceMode == .onDevice {
                    onDeviceModelsCard
                    importCard
                } else {
                    googleAIStudioCard
                }
            }
        }
        .fileImporter(
            isPresented: $importPickerPresented,
            allowedContentTypes: [UTType(filenameExtension: "litertlm") ?? .data],
            allowsMultipleSelection: false,
            onCompletion: importModel
        )
        .alert("Import failed", isPresented: .constant(importError != nil), actions: {
            Button("OK") { importError = nil }
        }, message: {
            Text(importError ?? "")
        })
    }

    private func importModel(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            let targetDirectory = modelLocator.importedModelsDirectory()
            try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
            let targetURL = targetDirectory.appendingPathComponent(sourceURL.lastPathComponent)

            let accessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            }

            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        } catch {
            importError = error.localizedDescription
        }
    }

    private var productionExecutionModePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Work mode")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(OceanPalette.ink)

            Picker("Work mode", selection: $appState.productionExecutionMode) {
                ForEach(ProductionExecutionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(spacing: 10) {
                ForEach(ProductionExecutionMode.allCases) { mode in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: appState.productionExecutionMode == mode ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(appState.productionExecutionMode == mode ? OceanPalette.reef : OceanPalette.ink.opacity(0.42))
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(mode.displayName) Mode: \(mode.shortLabel)")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(OceanPalette.ink)

                            Text(mode.detail)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(OceanPalette.ink.opacity(0.64))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(appState.productionExecutionMode == mode ? 0.62 : 0.42))
                    )
                }
            }
        }
    }

    private var processingLocationPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where to create")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(OceanPalette.ink)

            Picker("Where to create", selection: $appState.inferenceMode) {
                ForEach(InferenceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(appState.productionExecutionMode == .desk)

            if appState.productionExecutionMode == .desk {
                Text("In Desk Mode this choice is saved for later, but nothing is created here.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(OceanPalette.ink.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var onDeviceModelsCard: some View {
        OceanCard {
            OceanSectionHeader(title: "On-device models", detail: "Downloaded, imported, and injected are the same here")

            VStack(spacing: 12) {
                ForEach(ModelOption.allCases) { model in
                    onDeviceModelRow(model)
                }
            }
        }
    }

    private func onDeviceModelRow(_ model: ModelOption) -> some View {
        let availability = modelLocator.resolve(model)
        let downloadState = modelDownloadStore.state(for: model)
        let isAvailable = availability.url != nil

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isAvailable ? OceanPalette.reef : OceanPalette.coral)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(OceanPalette.ink)

                    Text(availability.detail)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Download source: \(model.downloadSourceName)")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            modelDownloadControls(for: model, state: downloadState, isAvailable: isAvailable)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.52))
        )
    }

    @ViewBuilder
    private func modelDownloadControls(for model: ModelOption, state: ModelDownloadState, isAvailable: Bool) -> some View {
        if state.isDownloading {
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: state.progressFraction)
                    .tint(OceanPalette.deepWater)

                HStack(spacing: 12) {
                    Text(state.statusText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(OceanPalette.deepWater)

                    Spacer(minLength: 8)

                    Button("Cancel") {
                        modelDownloadStore.cancelDownload(for: model)
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(OceanPalette.coral)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if case .failed = state {
                    Text(state.statusText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(OceanPalette.coral)
                        .fixedSize(horizontal: false, vertical: true)
                } else if case .completed = state {
                    Text(state.statusText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(OceanPalette.deepWater)
                }

                Button(isAvailable ? "Download fresh copy" : "Download model") {
                    modelDownloadStore.startDownload(for: model)
                }
                .buttonStyle(OceanPrimaryButtonStyle())
            }
        }
    }

    private var importCard: some View {
        OceanCard {
            OceanSectionHeader(title: "Add an on-device model")

            Button("Import .litertlm from Files") {
                importPickerPresented = true
            }
            .buttonStyle(OceanPrimaryButtonStyle())

            Text("Imported files are available for creating posts on this device.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var googleAIStudioCard: some View {
        OceanCard {
            OceanSectionHeader(title: "Google AI Studio access", detail: appState.hasGoogleAIStudioAPIKey ? "Key saved" : "Key required")

            VStack(alignment: .leading, spacing: 10) {
                Text("Google AI Studio API key")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(OceanPalette.ink)

                HStack(spacing: 12) {
                    Group {
                        if revealsCloudAPIKey {
                            TextField("AIza...", text: $appState.googleAIStudioAPIKey)
                        } else {
                            SecureField("AIza...", text: $appState.googleAIStudioAPIKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(OceanPalette.ink)

                    Button(revealsCloudAPIKey ? "Hide" : "Show") {
                        revealsCloudAPIKey.toggle()
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(OceanPalette.deepWater)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.55))
                )
            }

            Text("Cloud mode sends the post materials to a hosted model and returns the finished media and text.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            Text("Use this when the device is too slow or does not have a local model ready.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink.opacity(0.64))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(CloudModelOption.allCases) { model in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(OceanPalette.deepWater)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.displayName)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(OceanPalette.ink)

                            Text(model.detail)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(OceanPalette.ink.opacity(0.64))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.52))
                    )
                }
            }
        }
    }

    private func onDeviceModelPicker(title: String, selection: Binding<ModelOption>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(OceanPalette.ink)

            Picker(title, selection: selection) {
                ForEach(ModelOption.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.55))
            )
        }
    }

    private func cloudModelPicker(title: String, selection: Binding<CloudModelOption>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(OceanPalette.ink)

            Picker(title, selection: selection) {
                ForEach(CloudModelOption.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.55))
            )
        }
    }
}
