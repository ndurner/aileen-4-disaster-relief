import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var importPickerPresented = false
    @State private var importError: String?
    @State private var revealsCloudAPIKey = false

    private let modelLocator = ModelLocator()

    var body: some View {
        OceanScreen {
            AileenWorkflowCard(
                    imageName: "AileenSettingsScene",
                    title: "Choose my tools",
                    message: "Switch between on-device LiteRT inference and hosted Gemma 4 inference through Google AI Studio."
                ) {
                inferenceModePicker

                if appState.inferenceMode == .onDevice {
                    onDeviceModelPicker(title: "Visual model", selection: $appState.selectedProductionModel)
                    onDeviceModelPicker(title: "Post body model", selection: $appState.selectedTextModel)
                } else {
                    cloudModelPicker(title: "Visual model", selection: $appState.selectedCloudProductionModel)
                    cloudModelPicker(title: "Post body model", selection: $appState.selectedCloudTextModel)
                }
            }

            if appState.inferenceMode == .onDevice {
                onDeviceModelsCard
                importCard
            } else {
                googleAIStudioCard
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

    private var inferenceModePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inference mode")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(OceanPalette.ink)

            Picker("Inference mode", selection: $appState.inferenceMode) {
                ForEach(InferenceMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var onDeviceModelsCard: some View {
        OceanCard {
            OceanSectionHeader(title: "On-device models", detail: "Imported and injected are the same here")

            VStack(spacing: 12) {
                ForEach(ModelOption.allCases) { model in
                    let availability = modelLocator.resolve(model)
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: availability.url == nil ? "circle.dashed" : "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(availability.url == nil ? OceanPalette.coral : OceanPalette.reef)
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
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.52))
                    )
                }
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

            Text("Any imported `.litertlm` file is treated as an on-device model, just like a model copied in by the shared device script.")
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

            Text("Cloud mode uses the Gemma 4 models Google currently exposes through AI Studio: Gemma 4 26B A4B and Gemma 4 31B.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(OceanPalette.ink.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)

            Text("Requests go straight to Google-hosted Gemma 4 models through the Gemini API. OpenRouter-specific routing controls such as Exacto no longer apply.")
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
