import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var importPickerPresented = false
    @State private var importError: String?

    private let modelLocator = ModelLocator()

    var body: some View {
        OceanScreen(
            eyebrow: "Toolkit",
            title: "Settings",
            subtitle: "Choose how visuals and post copy are produced."
        ) {
            OceanCard {
                OceanSectionHeader(title: "Selected models")
                modelPicker(title: "Visual model", selection: $appState.selectedProductionModel)
                modelPicker(title: "Post body model", selection: $appState.selectedTextModel)
            }

            OceanCard {
                OceanSectionHeader(title: "Model source")

                Picker("Prefer", selection: $appState.preferredModelSource) {
                    ForEach(ModelSourcePreference.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                VStack(spacing: 12) {
                    ForEach(ModelOption.allCases) { model in
                        let availability = modelLocator.resolve(model, sourcePreference: appState.preferredModelSource)
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

            OceanCard {
                OceanSectionHeader(title: "Import a model")

                Button("Import .litertlm from Files") {
                    importPickerPresented = true
                }
                .buttonStyle(OceanPrimaryButtonStyle())

                Text("Downloads are not wired yet in-app. Use model injection or import a first-party `.litertlm` file here.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(OceanPalette.ink.opacity(0.64))
                    .fixedSize(horizontal: false, vertical: true)
            }

            OceanCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "video.badge.waveform")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(OceanPalette.deepWater)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(OceanPalette.tideFoam)
                        )

                    Text("The app uses Apple-native media rendering for on-device image and reel assembly on iPhone, iPad, and Designed for iPad on Mac.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(OceanPalette.ink.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
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

    private func modelPicker(title: String, selection: Binding<ModelOption>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(OceanPalette.ink)

            Picker(title, selection: selection) {
                ForEach(ModelOption.allCases) { model in
                    Text("\(model.displayName) (\(model.defaultUse))").tag(model)
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
