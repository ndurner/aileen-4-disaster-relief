import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var importPickerPresented = false
    @State private var importError: String?

    private let modelLocator = ModelLocator()

    var body: some View {
        NavigationStack {
            Form {
                Section("Model source") {
                    Picker("Prefer", selection: $appState.preferredModelSource) {
                        ForEach(ModelSourcePreference.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    ForEach(ModelOption.allCases) { model in
                        let availability = modelLocator.resolve(model, sourcePreference: appState.preferredModelSource)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.displayName)
                            Text(availability.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Import model") {
                    Button("Import .litertlm from Files") {
                        importPickerPresented = true
                    }
                    Text("Downloads are not wired yet in-app. Use model injection or import a first-party .litertlm file here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Media rendering") {
                    Text("The app uses Apple-native media rendering for on-device image and reel assembly on iPhone, iPad, and Designed for iPad on Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
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
}
