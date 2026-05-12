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
            OceanCard {
                OceanSectionHeader(title: "Creation settings")

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

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: appState.productionExecutionMode == .field ? "bolt.circle.fill" : "tray.and.arrow.up.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(OceanPalette.deepWater)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.productionExecutionMode.shortLabel)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(OceanPalette.ink)

                    Text(appState.productionExecutionMode.detail)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.52))
            )
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
            OceanSectionHeader(title: "On-device Gemma 4", detail: "E2B and E4B")

            Text("Download a model, or choose the matching file from Files.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(ModelOption.allCases) { model in
                    onDeviceModelRow(model)

                    if model.id != ModelOption.allCases.last?.id {
                        Divider()
                            .overlay(OceanPalette.deepWater.opacity(0.10))
                            .padding(.leading, 56)
                    }
                }
            }
        }
    }

    private func onDeviceModelRow(_ model: ModelOption) -> some View {
        let availability = modelLocator.resolve(model)
        let downloadState = modelDownloadStore.state(for: model)
        let isAvailable = availability.url != nil

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isAvailable ? OceanPalette.tideFoam : OceanPalette.coral.opacity(0.16))

                    Image(systemName: isAvailable ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(isAvailable ? OceanPalette.deepWater : OceanPalette.coral)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(model.displayName)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(OceanPalette.ink)

                        Text(isAvailable ? "Ready" : "Needed")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(isAvailable ? OceanPalette.deepWater : OceanPalette.coral)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isAvailable ? OceanPalette.tideFoam.opacity(0.95) : OceanPalette.coral.opacity(0.16))
                            )
                    }

                    Text(model.defaultUse)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink.opacity(0.64))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(availability.detail)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isAvailable ? OceanPalette.deepWater.opacity(0.78) : OceanPalette.ink.opacity(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            modelDownloadControls(for: model, state: downloadState, isAvailable: isAvailable)
        }
        .padding(.vertical, 16)
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

                HStack(spacing: 10) {
                    Button(isAvailable ? "Replace \(model.shortModelName)" : "Download \(model.shortModelName)") {
                        modelDownloadStore.startDownload(for: model)
                    }
                    .buttonStyle(OceanPrimaryButtonStyle())

                    Button {
                        importPickerPresented = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .buttonStyle(OceanSecondaryButtonStyle())
                }
            }
        }
    }

    private var googleAIStudioCard: some View {
        OceanCard {
            OceanSectionHeader(title: "Gemini API access", detail: appState.hasGoogleAIStudioAPIKey ? "Key saved" : "Key required")

            VStack(alignment: .leading, spacing: 10) {
                Text("Gemini API key")
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

            Text("Cloud creation uses the Gemini API with the selected Gemma 4 model.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            Text("Selected media is uploaded for the run, then removed after the finished post and media are returned.")
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
